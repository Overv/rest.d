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
alias string function() RequestHandler;

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
private class Request {
    string method;
    string path;

    // Field names are always lower case, e.g. content-length
    string[string] headers;

    private static enum requestLineRegex = ctRegex!(`^(GET) ([^ ]+) HTTP/1\.1$`);

    /**
     * Parse raw request into a structure.
     */
    this(ubyte[] buffer) {
        string raw = cast(string) buffer;
        string[] lines = raw.split("\r\n");

        // Parse request line
        auto reqLine = match(lines[0], requestLineRegex);
        method = reqLine.captures[1].toLower;
        path = reqLine.captures[2][1..$];

        // Parse headers
        foreach (string line; lines[1..$-2]) {
            string[] parts = line.split(":");

            string key = parts[0].strip.toLower;
            string value = parts[1].strip;

            headers[key] = value;
        }
    }
}

/**
 * A single-threaded HTTP 1.1 server handling requests for specified callbacks.
 *
 * TODO:
 * - Handle malformed requests (No host header, bad request line)
 * - Allow HTTP/1.0 requests (Drop host header requirement)
 * - Support request body
 * - Support keep-alive
 * - Support chunked transfer encoding from clients
 * - Support more than FD_SETSIZE concurrent connections (multiple select calls)
 * - Support POST/HEAD/PUT/DELETE, return 501 for other types
 * - Support omitting \r for newlines
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
        Request req = new Request(conn.buffer);

        RequestHandler* handler = req.path in getHandlers;

        if (handler) {
            string response = (*handler)();
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
