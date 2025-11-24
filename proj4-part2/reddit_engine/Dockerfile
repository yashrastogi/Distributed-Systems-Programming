# Stage 1: Build the application
FROM erlang:28

# Install Gleam with multi-architecture support
ARG TARGETARCH
RUN apt-get update && apt-get install -y curl tar

RUN curl -L -o gleam.tar.gz "https://github.com/gleam-lang/gleam/releases/download/v1.13.0/gleam-v1.13.0-aarch64-unknown-linux-musl.tar.gz"

RUN tar -xzf gleam.tar.gz
RUN mv gleam /usr/local/bin/gleam
RUN chmod +x /usr/local/bin/gleam
RUN rm gleam.tar.gz
RUN apt-get remove -y curl && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY . .
RUN gleam build

# Set the command to run the client simulator
CMD ["gleam", "run", "--module", "client_simulator"]
