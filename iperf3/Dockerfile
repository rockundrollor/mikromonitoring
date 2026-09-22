FROM alpine:3.20
RUN apk add --no-cache iperf3 curl jq bash coreutils
COPY run.sh /run.sh
RUN chmod +x /run.sh
ENTRYPOINT ["/run.sh"]
