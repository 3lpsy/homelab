FROM alpine:3.23

# 3proxy isn't in Alpine 3.23 main/community — only in edge/testing. Pull
# just that one package from testing; its only dependency is musl libc
# (stable soname), already satisfied by the 3.23 base, so no edge packages
# are dragged in. (testing is Alpine's least-stable repo — if a future
# rebuild ever fails to resolve, fall back to building from source.)
RUN apk add --no-cache 3proxy \
      --repository=https://dl-cdn.alpinelinux.org/alpine/edge/testing

EXPOSE 1080

# Foreground (no `daemon` directive in the config) so the container stays up.
ENTRYPOINT ["3proxy", "/etc/3proxy/3proxy.cfg"]
