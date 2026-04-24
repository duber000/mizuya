FROM golang:1.26 AS builder
WORKDIR /src

RUN go install github.com/kukichalang/kukicha/cmd/kukicha@v0.6.4

COPY . .

RUN CGO_ENABLED=0 kukicha build --no-line-directives . && mv src /mizuya

FROM alpine:latest
RUN apk add --no-cache ca-certificates
COPY --from=builder /mizuya /mizuya
ENTRYPOINT ["/mizuya"]
