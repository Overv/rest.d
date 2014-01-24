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

/**
 * Request handler function.
 */
alias string function(Request) RequestHandler;

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
 * Representation of a HTTP request.
 */
class Request {
    string method;
    string fullPath;

    string path;
    string[string] query;

    // Field names are always lower case, e.g. content-length
    string[string] headers;

    private static enum requestLineRegex = ctRegex!(`^(GET) (/[^ ]+) HTTP/1\.1$`);
    private static enum pathRegex = ctRegex!(`^/([^?#]*)`);
    private static enum queryRegex = ctRegex!(`^/[^?]*\?([^#]*)`);

    /**
     * Parse raw request into a structure.
     * Throws: Exception on bad request.
     */
    private this(ubyte[] buffer) {
        string raw = cast(string) buffer;
        string[] lines = raw.split("\r\n");

        // Request line, host header and empty line (splits to 4)
        enforce(lines.length >= 4, "Incomplete request");

        // Parse request line
        auto reqLine = match(lines[0], requestLineRegex);
        enforce(reqLine, "Malformed request line");

        method = reqLine.captures[1].toLower;
        fullPath = reqLine.captures[2];

        // Extract actual path
        path = match(fullPath, pathRegex).captures[1];

        // Parse query variables
        auto q = match(fullPath, queryRegex);

        if (q) {
            string[] pairs = q.captures[1].split("&");

            foreach (string pair; pairs) {
                string[] parts = pair.split("=");

                // Accept formats a=b/a=b=c=d/a
                if (parts.length == 1) {
                    query[parts[0]] = "";
                } else if (parts.length > 1) {
                    query[parts[0]] = pair[parts[0].length + 1..$];
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
}

/**
 * A single-threaded HTTP 1.1 server handling requests for specified callbacks.
 *
 * TODO:
 * - Add Response object for properly building response
 * - Support POST/HEAD/PUT/DELETE, return 501 for other types
 * - Support request body
 * - Support keep-alive (default unless Connection: close is specified)
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

    // Request handlers
    private RequestHandler[string] getHandlers;

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
                        if (isCompleteRequest(conn.buffer)) {
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
     * Checks if a buffer contains a complete request.
     */
    private bool isCompleteRequest(ubyte[] buffer) {
        return buffer.length >= 4 && buffer[$-4..$] == "\r\n\r\n";
    }

    /**
     * Respond to a request sent by a client.
     */
    private void handleRequest(Connection conn) {
        // Attempt to parse request
        Request req;
        try {
            req = new Request(conn.buffer);
        } catch (Exception e) {
            conn.socket.send("HTTP/1.1 400 Bad Request\r\n\r\n");
            return;
        }

        // Find matching handler to create response
        RequestHandler* handler = req.path in getHandlers;

        if (handler) {
            string response = (*handler)(req);
            conn.socket.send("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: " ~ to!string(response.length) ~"\r\n\r\n" ~ response);
        } else {
            conn.socket.send("HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 10\r\n\r\nNot found!");
        }
    }

    /**
     * Add a handler for GET requests.
     */
    void get(string path, RequestHandler handler) {
        getHandlers[path] = handler;
    }
}
