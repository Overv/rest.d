/**
 * Copyright: Revised BSD License
 * Authors: Alexander Overvoorde
 */

module rest;

import std.socket, std.container;

/**
 * Request handler function.
 */
alias string function() RequestHandler;

/**
 * A single-threaded HTTP 1.1 server handling requests for specified callbacks.
 *
 * TODO:
 * - Limit connections per IP
 * - Timeout for connections
 * - Limit request size
 * - Support keep-alive
 * - Support more than FD_SETSIZE concurrent connections (multiple select calls)
 */
class HttpServer {
    private Socket listener;
    private auto clients = new RedBlackTree!(Socket, "a.handle > b.handle");

    // Limited by FD_SETSIZE
    private uint maxClients = (new SocketSet).max;

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
     * Perform one iteration (accept new clients, receive data and handle
     * complete requests).
     * This function does not block on socket I/O.
     */
    void iterate() {
        acceptClients();
        receiveData();
    }

    /**
     * Accept new clients from the listener.
     */
    private void acceptClients() {
        // Accept all connections in backlog (exception thrown when empty)
        try {
            while (clients.length < maxClients) {
                Socket client = listener.accept();
                client.blocking = false;
                clients.insert(client);
            }
        } catch (SocketAcceptException e) {}
    }

    /**
     * Read data from clients.
     */
    private void receiveData() {
        // Create fd_set with all connected clients
        SocketSet readSet = new SocketSet;
        foreach (Socket client; clients) readSet.add(client);

        // Check for read state changes (data available, closed connection)
        int changes = Socket.select(readSet, null, null, dur!"hnsecs"(0));

        // Handle those sockets
        if (changes > 0) {
            ubyte[4096] buf;
            SList!Socket closedClients;

            foreach (Socket client; clients) {
                if (readSet.isSet(client)) {
                    auto len = client.receive(buf);

                    // 0 bytes to read means a closed connection
                    if (len == 0) {
                        closedClients.insert(client);
                    } else {
                        // TODO: Add data to buffer
                    }
                }
            }

            // Clean up closed sockets
            foreach (Socket client; closedClients) {
                clients.removeKey(client);
            }
        }
    }

    /**
     * Add a handler for GET requests.
     */
    void get(string path, RequestHandler handler) {
        // TODO: Implement
    }
}
