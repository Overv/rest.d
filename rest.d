/**
 * Copyright: Revised BSD License
 * Authors: Alexander Overvoorde
 */

module rest;

import std.container, std.datetime;
import std.socket, std.uri, std.zlib;
import std.array, std.string, std.conv, std.regex;

/**
 * Request handler function.
 */
alias Response function(Request) RequestHandler;

/**
 * Representation of a unique connection along with its state.
 */
private class Connection {
    Socket socket;
    ubyte[] buffer;
    SysTime start, last;

    this(Socket socket) {
        this.socket = socket;
        this.start = Clock.currTime;
        this.last = start;
    }

    socket_t id() {
        return socket.handle;
    }
}

/**
 * Representation of an HTTP request.
 */
class Request {
    Address ip;
    string method;
    string fullPath;

    string path;
    string[string] query;

    // Field names are always lower case, e.g. content-length
    string[string] headers;

    // Request body, length 0 if there is none
    ubyte[] rawBody;

    // Body parsed into key/values, empty if there is no (form) data
    string[string] form;

    // Complete if there's no body or complete body was received
    private bool complete;

    private static enum requestLineRegex = ctRegex!(`^(GET|POST|PUT|DELETE|HEAD) (/[^ ]*) HTTP/1\.1$`);
    private static enum pathRegex = ctRegex!(`^/([^?#]*)`);
    private static enum queryRegex = ctRegex!(`^/[^?]*\?([^#]*)`);

    /**
     * Parse (partial) request into a structure.
     * Throws: Exception on bad request.
     *
     * Note that an exception is only thrown if the request so far already
     * contains errors. Check isComplete to see if the request is actually
     * ready for processing.
     */
    private this(Connection conn) {
        string raw = cast(string) conn.buffer;
        string[] lines = raw.splitLines();

        // Request line, host header and empty line
        enforce(lines.length >= 3, "Incomplete request");

        // Parse request line
        auto reqLine = match(lines[0], requestLineRegex);
        enforce(reqLine, "Malformed request line");

        ip = conn.socket.remoteAddress;
        method = reqLine.captures[1].toLower;
        fullPath = reqLine.captures[2];

        // Extract actual path
        path = decode(match(fullPath, pathRegex).captures[1]);

        // Parse query variables
        auto q = match(fullPath, queryRegex);
        if (q) query = parseKeyValues(q.captures[1]);

        // Parse headers
        foreach (string line; lines[1..$]) {
            if (line.length == 0) break;

            string[] parts = line.split(":");

            enforce(parts.length >= 2, "Malformed header line");

            string key = parts[0].strip.toLower;
            string value = line[parts[0].length + 1..$].strip;

            headers[key] = value;
        }

        // HTTP/1.1 requires the Host header
        enforce("host" in headers, "Missing required Host header");

        // If there's a Content-Length header, check if its value is a number
        long bodyLength = 0;

        if ("content-length" in headers) {
            try {
                bodyLength = to!long(headers["content-length"]);
            } catch (ConvException e) {
                throw new Exception("Content length isn't numeric");
            }
        }

        // Read body if fully received
        if (bodyLength > 0) {
            long bodyStart = (cast(string) conn.buffer).indexOf("\r\n\r\n") + 4;

            // Make sure the buffer only contains the request and the body
            enforce(conn.buffer.length <= bodyStart + bodyLength, "Too much data sent");

            // Entire body has been received
            if (conn.buffer.length == bodyStart + bodyLength) {
                rawBody = conn.buffer[bodyStart..$];

                // If it contains key-value pairs, parse those
                if ("content-type" in headers && headers["content-type"] == "application/x-www-form-urlencoded") {
                    form = parseKeyValues(cast(string) rawBody);
                }

                complete = true;
            } else {
                complete = false;
            }
        } else {
            complete = true;
        }
    }

    /**
     * Parse url encoded key/value pairs into an associative array.
     */
    private string[string] parseKeyValues(string raw) {
        string[string] map;

        string[] pairs = raw.strip.split("&");

        foreach (string pair; pairs) {
            string[] parts = pair.split("=");

            // Accept formats a=b/a=b=c=d/a
            if (parts.length == 1) {
                string key = decode(parts[0]);

                map[key] = "";
            } else if (parts.length > 1) {
                string key = decode(parts[0]);
                string value = decode(pair[parts[0].length + 1..$]);

                map[key] = value;
            }
        }

        return map;
    }

    /**
     * Return true if the client accepts a gzip compressed response.
     */
    private bool acceptsGzip() {
        return ("accept-encoding" in headers) &&
               headers["accept-encoding"].indexOf("gzip") != -1;
    }

    /**
     * Return true if the client wants to use a persistent connection.
     */
    private bool keepAlive() {
        return !("connection" in headers) ||
               headers["connection"].toLower != "close";
    }

    /**
     * Return true if the entire request, including any body, has been received.
     */
    private bool isComplete() {
        return complete;
    }
}

/**
 * HTTP response status codes.
 */
enum Status {
    OK = 200,
    BadRequest = 400,
    NotFound = 404,
    InternalServerError = 500,
    NotImplemented = 501
}

/**
 * Get the text corresponding to a status code.
 */
private string statusText(Status code) {
    switch (code) {
        case Status.OK: return "OK";
        case Status.BadRequest: return "Bad Request";
        case Status.NotFound: return "Not Found";
        case Status.InternalServerError: return "Internal Server Error";
        case Status.NotImplemented: return "Not Implemented";
        default: return "";
    }
}

/**
 * Representation of an HTTP response.
 */
struct Response {
    private string response = "";
    private Status status = Status.OK;
    private string[string] headers;

    /**
     * Create a response by serializing an object to a string with to!string.
     */
    this(T)(T response, Status status = Status.OK) {
        this.response = to!string(response);
        this.status = status;

        // Default values for headers that may be overwritten
        headers["server"] = "rest.d";
        headers["content-type"] = "text/plain";
    }

    /**
     * Create an empty response (for example appropriate for bad request).
     */
    this(Status status) {
        this("", status);
    }

    /**
     * Add a header to the response or change its value.
     *
     * Silently fails for headers like Content-Length, Content-Encoding
     * and Connection, which affect framework operations (later overriden).
     * Note that the name is capitalized automatically, so cONTENT-lEnGth
     * becomes Content-Length.
     */
    void setHeader(string name, string value) {
        enforce(name.indexOf(":") == -1 && name.indexOf(" ") == -1, "Header name invalid");
        enforce(value.strip.length > 0, "Header value may not be empty");

        headers[name.toLower] = value;
    }

    /**
     * Turn the response into a HTTP response.
     *
     * The request is used to determine how to create a response, for example if
     * gzip compression can be used. The default value of null should only be
     * used in case of a bad request, where no object is available.
     */
    private string generate(Request req = null) {
        // Check if a persistent connection is desired
        if (!(req is null) && req.keepAlive) {
            headers["connection"] = "keep-alive";
        } else {
            headers["connection"] = "close";
        }

        // Only send a response body if the request wasn't HEAD
        string content = "";
        if ((req is null || req.method != "head") && response.length > 0) {
            // Prepare a compressed response if the client accepts it
            ubyte[] compressed;
            if (!(req is null) && req.acceptsGzip) {
                compressed = gzip(cast(ubyte[]) response);
            }

            // Send the compressed response only if it's actually smaller
            if (compressed.length > 0 && compressed.length < response.length) {
                headers["content-encoding"] = "gzip";
                headers["content-length"] = to!string(compressed.length);
                content = cast(string) compressed;
            } else {
                headers["content-length"] = to!string(response.length);
                content = response;
            }
        } else {
            headers["content-length"] = "0";
        }

        // Compose message
        string msg = "HTTP/1.1 " ~ to!string(cast(int) status) ~ " " ~ statusText(status) ~ "\r\n";

        foreach (string name, value; headers) {
            msg ~= capitalizeHeader(name) ~ ": " ~ value ~ "\r\n";
        }

        msg ~= "\r\n";
        msg ~= content;

        return msg;
    }

    /**
     * Capitalize a header name properly.
     */
    private static string capitalizeHeader(string name) {
        string[] parts = name.split("-");

        for (int i = 0; i < parts.length; i++) {
            parts[i] = parts[i].capitalize;
        }

        return join(parts, "-");
    }

    /**
     * Compress data with gzip with maximum compression (level 9).
     */
    private static ubyte[] gzip(ubyte[] data) {
        Compress c = new Compress(9, HeaderFormat.gzip);

        ubyte[] compressed = cast(ubyte[]) c.compress(data);
        compressed ~= cast(ubyte[]) c.flush;

        return compressed;
    }
}

/**
 * A single-threaded HTTP 1.1 server handling requests for specified callbacks.
 *
 * TODO:
 * - Support chunked transfer encoding from clients
 */
class HttpServer {
    private Socket listener;
    private auto connections = new RedBlackTree!(Connection, "a.id > b.id");

    // Limited by FD_SETSIZE
    private const uint maxConnections = (new SocketSet).max;

    // Configuration
    private const uint maxRequestSize = 4096;
    private const Duration keepAliveTimeout = dur!"seconds"(5);
    private const Duration requestTimeout = dur!"seconds"(5);

    // Request handlers (method -> path -> callback)
    private RequestHandler[string][string] handlers;

    /**
     * Create server and start listening.
     * Throws: SocketOSException if a process is already listening on the port.
     */
    this(ushort port = 80, int backlog = 16) {
        listener = new TcpSocket;
        listener.blocking = false;
        listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        listener.bind(new InternetAddress(port));
        listener.listen(backlog);
    }

    /**
     * Block execution and hand control over to this server object.
     */
    void loop() {
        while (true) {
            iterate();
        }
    }

    /**
     * Perform one iteration (accept new connections, receive data and handle
     * complete requests).
     * This function does not block on socket I/O.
     */
    void iterate() {
        acceptConnections();
        receiveData();
    }

    /**
     * Accept new clients from the listener.
     */
    private void acceptConnections() {
        // Accept all connections in backlog (exception thrown when empty)
        try {
            while (connections.length < maxConnections) {
                Socket sock = listener.accept();
                sock.blocking = false;
                connections.insert(new Connection(sock));
            }
        } catch (SocketAcceptException e) {}
    }

    /**
     * Read data from clients.
     */
    private void receiveData() {
        // List for closed connections
        SList!Connection closedConnections;

        // Create fd_set with all connected sockets
        SocketSet readSet = new SocketSet;
        SysTime t = Clock.currTime;

        foreach (Connection conn; connections) {
            // Clean up closed sockets
            if (conn.socket.isAlive) {
                // Drop connection if no complete request was sent in time or if
                // the connection has been kept alive too long.
                if (t - conn.last > requestTimeout || t - conn.start > keepAliveTimeout) {
                    conn.socket.close();
                    closedConnections.insert(conn);
                } else {
                    readSet.add(conn.socket);
                }
            } else {
                closedConnections.insert(conn);
            }
        }

        // Check for read state changes (data available, closed connection)
        int changes = Socket.select(readSet, null, null, dur!"hnsecs"(0));

        // Handle those state changes
        if (changes > 0) {
            ubyte[maxRequestSize] buf;

            foreach (Connection conn; connections) {
                if (readSet.isSet(conn.socket)) {
                    auto len = conn.socket.receive(buf);

                    // 0 bytes to read means a closed connection
                    if (len == 0) {
                        closedConnections.insert(conn);
                    } else {
                        conn.buffer ~= buf[0..len];

                        // If request is too large, drop client
                        if (conn.buffer.length > maxRequestSize) {
                            conn.socket.close();
                            closedConnections.insert(conn);
                        }

                        // Handle request if client has sent a complete one
                        if (hasCompleteRequest(conn)) {
                            bool keepAlive = handleRequest(conn);

                            if (!keepAlive) {
                                conn.socket.close();
                                closedConnections.insert(conn);
                            } else {
                                // Reset state for next request
                                conn.last = Clock.currTime;
                                conn.buffer.length = 0;
                            }
                        }
                    }
                }
            }
        }

        // Clean up closed connections
        foreach (Connection conn; closedConnections) {
            connections.removeKey(conn);
        }
    }

    /**
     * Check if a client has sent a complete request.
     */
    private static bool hasCompleteRequest(Connection conn) {
        // If not all headers have been received yet, continue waiting
        if ((cast(string) conn.buffer).indexOf("\r\n\r\n") == -1) return false;

        // Otherwise parse (partial) request to check if it's complete
        Request req;
        try {
            req = new Request(conn);
        } catch (Exception e) {
            // Bad request should be handled now
            return true;
        }

        return req.isComplete;
    }

    /**
     * Respond to a request sent by a client.
     * Returns true if the connection should remain open (keep alive).
     */
    private bool handleRequest(Connection conn) {
        // Attempt to parse request, bad request means closing the connection
        Request req;
        try {
            req = new Request(conn);
        } catch (Exception e) {
            conn.socket.send(Response(Status.BadRequest).generate);
            return false;
        }

        // Find matching handler to create response
        RequestHandler* handler;
        Response res;
        if (req.method in handlers) handler = req.path in handlers[req.method];

        // If there is no handler, return a not found error
        if (handler) {
            // If the handler fails, recover with an internal server error
            try {
                res = (*handler)(req);
            } catch (Error e) {
                res = Response(Status.InternalServerError);
            }
        } else {
            res = Response("Not found!", Status.NotFound);
        }

        // Send the response to the client
        conn.socket.send(res.generate(req));

        // Depending on the request, keep the connection open
        return req.keepAlive;
    }

    /**
     * Add a handler for GET requests.
     */
    void get(string path, RequestHandler handler) {
        handlers["get"][path] = handler;
        handlers["head"][path] = handler;
    }

    /**
     * Add a handler for POST requests.
     */
    void post(string path, RequestHandler handler) {
        handlers["post"][path] = handler;
    }

    /**
     * Add a handler for PUT requests.
     */
    void put(string path, RequestHandler handler) {
        handlers["put"][path] = handler;
    }

    /**
     * Add a handler for DELETE requests.
     */
    void del(string path, RequestHandler handler) {
        handlers["delete"][path] = handler;
    }

    /**
     * Add a handler for any method.
     */
    void request(string path, RequestHandler handler) {
        get(path, handler);
        post(path, handler);
        put(path, handler);
        del(path, handler);
    }
}
