# syntax=docker/dockerfile:1
FROM --platform=$BUILDPLATFORM docker.io/busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec AS filter
COPY filter.sh /filter.sh
RUN --mount=type=bind,from=app,target=/app sh /filter.sh /app /out

FROM app
COPY --from=filter /out/ /
