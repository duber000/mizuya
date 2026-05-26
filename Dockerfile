FROM golang:1.26 AS builder
WORKDIR /src

RUN go install github.com/kukichalang/kukicha/cmd/kukicha@v0.22.0 && kukicha version

COPY . .

RUN CGO_ENABLED=0 kukicha build --no-line-directives . && mv src /mizuya

# Runtime stage — distroless (no shell; ca-certificates included)
FROM gcr.io/distroless/static-debian12
COPY --from=builder --chown=65532:65532 /mizuya /mizuya
USER 65532
ENTRYPOINT ["/mizuya"]
