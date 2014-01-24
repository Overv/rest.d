/**
 * Copyright: Revised BSD License
 * Authors: Alexander Overvoorde
 */

module rest;

import std.socket;
import std.container;
import std.datetime;
import std.array;
import std.string;
import std.conv;
import std.regex;
import std.zlib;
import std.uri;

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
    SysTime start;

    this(Socket socket) {
        this.socket = socket;
        this.start = Clock.currTime;
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

    private static enum requestLineRegex = ctRegex!(`^(GET|POST|PUT|DELETE|HEAD) (/[^ ]*) HTTP/1\.1$`);
    private static enum pathRegex = ctRegex!(`^/([^?#]*)`);
    private static enum queryRegex = ctRegex!(`^/[^?]*\?([^#]*)`);

    /**
     * Parse raw request into a structure.
     * Throws: Exception on bad request.
     */
    private this(Connection conn) {
        string raw = cast(string) conn.buffer;
        string[] lines = raw.split("\r\n");

        // Request line, host header and empty line (splits to 4)
        enforce(lines.length >= 4, "Incomplete request");

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

        if (q) {
            string[] pairs = q.captures[1].split("&");

            foreach (string pair; pairs) {
                string[] parts = pair.split("=");

                // Accept formats a=b/a=b=c=d/a
                if (parts.length == 1) {
                    string key = decode(parts[0]);

                    query[key] = "";
                } else if (parts.length > 1) {
                    string key = decode(parts[0]);
                    string value = decode(pair[parts[0].length + 1..$]);

                    query[key] = value;
                }
            }
        }

        // Parse headers
        foreach (string line; lines[1..$-2]) {
            string[] parts = line.split(":");

            enforce(parts.length >= 2, "Malformed header line");

            string key = parts[0].strip.toLower;
            string value = line[parts[0].length + 1..$].strip;

            headers[key] = value;
        }

        // HTTP/1.1 requires the Host header
        enforce("host" in headers, "Missing required Host header");
    }

    /**
     * Checks if a buffer contains a complete request.
     */
    private static bool isCompleteRequest(ubyte[] buffer) {
        return buffer.length >= 4 && buffer[$-4..$] == "\r\n\r\n";
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
private  string statusText(Status code) {
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

    /**
     * Create a response by serializing an object to a string with to!string.
     */
    this(T)(T response, Status status = Status.OK) {
        this.response = to!string(response);
        this.status = status;
    }

    /**
     * Create an empty response (for example appropriate for bad request).
     */
    this(Status status) {
        this.response = "";
        this.status = status;
    }

    /**
     * Turn the response into a HTTP response.
     */
    private string generate(bool head = false) {
        string msg = "";

        msg ~= "HTTP/1.1 " ~ to!string(cast(int) status) ~ " " ~ statusText(status) ~ "\r\n";
        msg ~= "Content-Type: text/plain\r\n";

        // If request was HEAD, don't send response body
        if (!head && response.length > 0) {
            msg ~= "Content-Length: " ~ to!string(response.length) ~ "\r\n\r\n";
            msg ~= response;
        } else {
            msg ~= "\r\n";
        }

        return msg;
    }
}

/**
 * A single-threaded HTTP 1.1 server handling requests for specified callbacks.
 *
 * TODO:
 * - Support gzip compression
 * - Support adding headers to response
 * - Support request body
 * - Support keep-alive (default unless Connection: close is specified)
 * - Support JSON serialization
 * - Support chunked transfer encoding from clients
 */
class HttpServer {
    private Socket listener;
    private auto connections = new RedBlackTree!(Connection, "a.id > b.id");

    // Limited by FD_SETSIZE
    private uint maxConnections = (new SocketSet).max;

    // Configuration
    private const uint maxRequestSize = 4096;
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
                // Drop connection if no complete request was sent in time
                if (t - conn.start > requestTimeout) {
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

                        // If request is too large, drop conn
                        if (conn.buffer.length > maxRequestSize) {
                            conn.socket.close();
                            closedConnections.insert(conn);
                        }

                        // Handle request if buffer contains full request
                        if (Request.isCompleteRequest(conn.buffer)) {
                            handleRequest(conn);

                            conn.socket.close();
                            closedConnections.insert(conn);
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
     * Respond to a request sent by a client.
     */
    private void handleRequest(Connection conn) {
        // Attempt to parse request
        Request req;
        try {
            req = new Request(conn);
        } catch (Exception e) {
            conn.socket.send(Response(Status.BadRequest).generate);
            return;
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

        conn.socket.send(res.generate(req.method == "head"));
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
