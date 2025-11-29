# Reddit Engine - Project 4 Part 2 Report

## Group Members
- Yash Rastogi
- Pavan Karthik Chilla

## Demo Videos
- **Core Project Demo**: https://youtu.be/IiPps98lRVA
- **Bonus Demo (Digital Signatures)**: https://youtu.be/WUGYkS89Ixs

---

## Implementation Summary

### REST API Design

The Reddit Engine exposes a REST API built with Gleam using the Wisp web framework. The server runs on port 8080 and handles all requests through a central actor that manages state.

**Key Endpoints:**

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/users` | Register user (optionally with public key) |
| POST | `/subreddits` | Create subreddit |
| PUT | `/users/{user}/subscriptions/{sub}` | Join subreddit |
| DELETE | `/users/{user}/subscriptions/{sub}` | Leave subreddit |
| POST | `/subreddits/{sub}/posts` | Create post (with optional signature) |
| POST | `/posts/{id}/votes` | Vote on post |
| POST | `/subreddits/{sub}/posts/{id}/comments` | Comment on post |
| POST | `/comments/{id}/replies` | Reply to comment |
| POST | `/dms` | Send direct message |
| GET | `/users/{user}/feed` | Get user's feed |
| GET | `/users/{user}/dms` | Get direct messages |
| GET | `/users/{user}/karma` | Get karma score |
| GET | `/users/{user}/public_key` | Get user's public key |
| GET | `/search/usernames?q=` | Search users |
| GET | `/search/subreddits?q=` | Search subreddits |
| GET | `/metrics` | Get engine metrics |

### Client Functionality

**1. Concurrent User Simulator (`client_simulator.gleam`)**
- Simulates 1000+ concurrent users as independent actors
- Users follow Zipf distribution for subreddit joins (popular subs get more members)
- Simulates realistic behavior: register → join subreddits → post/comment/vote cycles
- Reports performance metrics at completion

**2. REST API Demo (`demo_main.sh`)**
- Interactive bash script demonstrating all API endpoints
- Shows user registration, subreddit creation, posting, commenting, voting, DMs, and search

**3. Signed Posts Demo (`demo_signed_posts.sh`)**
- Demonstrates the bonus public key signature feature
- Generates RSA key pair, registers user with public key, creates signed post

### Server Architecture

The engine uses the actor model (via Gleam OTP) with a single stateful actor handling:
- User management (registration, karma tracking)
- Subreddit management (creation, membership)
- Content management (posts, comments, votes)
- Direct messaging
- Performance metrics

---

## How to Run

### Prerequisites
- Gleam 1.x installed
- Erlang/OTP runtime

### Start the Server
```bash
cd reddit_engine
gleam run
```
Server starts on `http://localhost:8080`

> **Note:** The server keeps all state in memory. Restart the server (`Ctrl+C` then `gleam run`) between demo/simulator runs for a fresh state.

### Run the Main Demo
```bash
./demo_main.sh
```
Walks through all API features with colored output.

### Run the Simulator
```bash
gleam run -m client_simulator
```
Spawns 1000 (customizable) concurrent user actors.

### Run the Simulator in Docker (Network Demo)
To demonstrate the client and server communicating over the network, a Dockerfile is included to run the simulator in a container while the server runs on the host:
```bash
# Start the server on host
gleam run

# In another terminal, build and run the client in Docker
docker build -t reddit-client .
docker run --rm reddit-client
```

### Run the Signed Posts Demo
```bash
./demo_signed_posts.sh
```
Demonstrates digital signature workflow.

---

## Bonus: Digital Signature Implementation

### Overview
Users can register with an RSA-2048 public key. When posting, they sign the content with their private key. The server verifies signatures when posts are retrieved.

### How It Works

1. **Key Generation** (client-side with OpenSSL):
   ```bash
   openssl genrsa -out private_key.pem 2048
   openssl rsa -in private_key.pem -RSAPublicKey_out -out public_key.pem
   ```

2. **Registration with Public Key**:
   ```bash
   curl -X POST /users -d "username=bob&public_key=<PEM_ENCODED>"
   ```

3. **Signing Posts** (`sign.gleam`):
   - Takes content and private key as arguments
   - Uses `rsa_keys` library to sign with SHA256 hash
   - Returns base64-encoded signature

4. **Creating Signed Post**:
   ```bash
   curl -X POST /subreddits/<sub>/posts \
     -H "Authorization: Username bob" \
     -d "title=...&content=...&signature=<BASE64_SIG>"
   ```

5. **Verification on Retrieval**:
   - When fetching feeds, server retrieves author's public key
   - Verifies signature against post content
   - Returns `signature_verified: true/false` in response, in case user does not have a public key associated, the value is by default, false

### Crypto Library
Uses `rsa_keys` Gleam library which wraps Erlang's `public_key` module for RSA operations with SHA256 hashing.

---

## Simulator Details

### Zipf Distribution for Subreddit Popularity

The simulator models realistic subreddit popularity using Zipf's law, where the probability of joining a subreddit at rank *r* is proportional to 1/*r*:

```
Rank 1 (gaming):      36.0% probability
Rank 2 (technology):  18.0% probability
Rank 3 (movies):      12.0% probability
...and so on
```

This ensures popular subreddits get disproportionately more members, mimicking real Reddit behavior.

### User Behavior Simulation

Each simulated user actor performs:
1. **Registration** → registers via REST API
2. **Join subreddits** → follows Zipf distribution
3. **Activity cycles** → alternates between online (active) and offline (idle) periods
4. **Actions while online**: create posts (30%), comment (20%), vote (20%), send DMs (20%), check feed (10%)

### Configuration

Edit `client_simulator.gleam` to adjust:
- `clients` constant: number of simulated users (default: 999)
- `api_host` / `api_port`: server address
- `subreddits_by_rank`: list of subreddits with popularity rankings

---

## Project Structure

```
reddit_engine/
├── src/
│   ├── reddit_engine.gleam      # Main engine actor and handlers
│   ├── client_simulator.gleam   # Concurrent user simulator
│   ├── models.gleam             # Data types (User, Post, Comment, etc.)
│   ├── sign.gleam               # CLI signing utility (bonus)
│   └── api/
│       ├── router.gleam         # REST API route handlers
│       └── middleware.gleam     # Auth and request middleware
├── demo_main.sh                 # Interactive API demo script
├── demo_signed_posts.sh         # Bonus signature demo script
├── Dockerfile                   # For running simulator over network
└── gleam.toml                   # Project dependencies
```

---

## References

- Gleam Language: https://gleam.run/
- Wisp Web Framework: https://hexdocs.pm/wisp/
- Erlang OTP: https://www.erlang.org/doc/
- Reddit API (inspiration): https://www.reddit.com/dev/api/
- Zipf's Law: https://en.wikipedia.org/wiki/Zipf%27s_law
