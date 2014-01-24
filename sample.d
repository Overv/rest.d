import rest;

import std.conv;
import std.datetime;

void main() {
    HttpServer server = new HttpServer(8080);

    server.get("time", function string() {
        return to!string(Clock.currTime);
    });

    server.loop();
}
