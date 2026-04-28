FROM golang:1.26 AS builder
WORKDIR /src

RUN go install github.com/kukichalang/kukicha/cmd/kukicha@v0.7.2

COPY . .

RUN CGO_ENABLED=0 kukicha build --no-line-directives . || (sed -n '305,315p' main.go && false) && mv src /mizuya

FROM alpine:latest
RUN apk add --no-cache ca-certificates
COPY --from=builder /mizuya /mizuya
ENTRYPOINT ["/mizuya"]
