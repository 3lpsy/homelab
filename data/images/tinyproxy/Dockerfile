FROM alpine:3.20

RUN apk add --no-cache tinyproxy

EXPOSE 8888

ENTRYPOINT ["tinyproxy", "-d", "-c", "/etc/tinyproxy/tinyproxy.conf"]
