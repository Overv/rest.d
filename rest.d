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
 * - Error handling (SocketAcceptException, SocketParameterException for SocketSet.add)
 * - Limit connections per IP to configurated number
 * - Timeout for connections
 * - Clean up resources for disconnected sockets (read returns 0 bytes)
 * - Support keep-alive
 */
class HttpServer {
    private Socket listener;

    private SList!Socket clients;
    private uint clientCount;

    // Set by querying FD_SETSIZE
    private uint maxClients;

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

        maxClients = (new SocketSet).max;
        clientCount = 0;
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
     */
    void iterate() {
        acceptClients();
    }

    /**
     * Accept new clients from the listener.
     */
    private void acceptClients() {
        // Accept all connections in backlog (exception thrown when empty)
        try {
            while (clientCount < maxClients) {
                Socket client = listener.accept();
                clients.insert(client);
                clientCount++;
            }
        } catch (SocketAcceptException e) {}
    }

    /**
     * Add a handler for GET requests.
     */
    void get(string path, RequestHandler handler) {
        // TODO: Implement
    }
}
