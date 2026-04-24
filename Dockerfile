FROM golang:1.26-alpine AS builder
WORKDIR /build
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o mizuya .

FROM alpine:latest
RUN apk add --no-cache ca-certificates
COPY --from=builder /build/mizuya /mizuya
ENTRYPOINT ["/mizuya"]
