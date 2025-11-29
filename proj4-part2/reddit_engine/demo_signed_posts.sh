#!/bin/bash

BASE_URL="http://192.168.139.3:8080"
DELAY=2
LONG_DELAY=5

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Starting Signed Posts Public Key Demo...${NC}"
echo "Press ENTER to continue or Ctrl+C to cancel."
read

function print_header() {
    echo -e "\n${BLUE}==============================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}==============================================${NC}"
}

function print_request() {
    echo -e "${CYAN}> $1${NC}"
}

function print_command() {
    echo -e "${NC}> $1${NC}"
}

# --- Key Management ---
print_header "1. Generating RSA Public/Private Key Pair"
echo "Generating RSA public/private key pair using openssl..."
print_command "openssl genrsa -out private_key.pem 2048"
openssl genrsa -out private_key.pem 2048
print_command "openssl rsa -pubout -in private_key.pem -RSAPublicKey_out -out public_key.pem"
openssl rsa -pubout -in private_key.pem -RSAPublicKey_out -out public_key.pem
echo "Key pair generated: private_key.pem and public_key.pem"
echo -e "\n\n"
read -p "Private key will be used to sign the message and a signature is sent along with the submitted post, while the public key is registered with the server for user 'bob' which will be used to verify the signature. Press ENTER to continue..."

# Store public key in a variable for user registration
PUBKEY="$(<public_key.pem)"$'\n\n'
ENCODED_PUBKEY=$(jq -rn --arg x "$PUBKEY" '$x|@uri')

# Store private key in a variable for signing posts
PRIVKEY="$(<private_key.pem)"$'\n\n'

# Clean up function
cleanup() {
    echo -e "\n${YELLOW}Cleaning up generated key files...${NC}"
    rm -f private_key.pem public_key.pem
}
trap cleanup EXIT # Ensure cleanup on exit

# --- End Key Management ---

print_header "2. Registering Users"
print_request "Registering user 'alice'..."
print_command "curl -X POST $BASE_URL/users -d 'username=alice'"
curl -s -X POST "$BASE_URL/users" -d "username=alice" | jq
sleep $DELAY

echo -e "\n"
print_request "Registering user 'bob' with public key..."
print_command "curl -X POST $BASE_URL/users -d 'username=bob&public_key=$ENCODED_PUBKEY'"
curl -s -X POST "$BASE_URL/users" -d "username=bob&public_key=$ENCODED_PUBKEY" | jq
sleep $LONG_DELAY

# 3. Create Subreddit
print_header "3. Creating Subreddit"
print_request "Alice creates subreddit 'GleamRocks'..."
print_command "curl -s -X POST -H 'Authorization: Username alice' $BASE_URL/subreddits -d 'title=GleamRocks' -d 'description=Everything about Gleam'"
curl -s -X POST -H "Authorization: Username alice" "$BASE_URL/subreddits" \
  -d "title=GleamRocks" \
  -d "description=Everything about Gleam" | jq
sleep $DELAY

# 4. Join Subreddit
print_header "4. Joining Subreddit"
print_request "Bob joins 'GleamRocks'..."
print_command "curl -s -X PUT -H 'Authorization: Username bob' $BASE_URL/users/bob/subscriptions/GleamRocks"
curl -s -X PUT -H "Authorization: Username bob" "$BASE_URL/users/bob/subscriptions/GleamRocks" | jq
echo -e "\n"
print_request "Alice joins 'GleamRocks'..."
print_command "curl -s -X PUT -H 'Authorization: Username alice' $BASE_URL/users/alice/subscriptions/GleamRocks"
curl -s -X PUT -H "Authorization: Username alice" "$BASE_URL/users/alice/subscriptions/GleamRocks" | jq
sleep $DELAY

# 5. Create Post by Bob with Signature
print_header "5. Bob Creates a Signed Post"
POST_CONTENT="This is Bob's first post in GleamRocks, signed with his private key!"
ENCODED_POST_CONTENT=$(jq -rn --arg x "$POST_CONTENT" '$x|@uri')

print_request "Signing post content using Bob's private key..."
print_command "gleam run -m sign \$POST_CONTENT \$PRIVKEY"
SIGNATURE=$(gleam run -m sign "$POST_CONTENT" "$PRIVKEY")
ENCODED_SIGNATURE=$(jq -rn --arg x "$SIGNATURE" '$x|@uri')


echo -e "\n"
print_request "Bob posts in 'GleamRocks' with the generated signature..."
print_command "curl -s -X POST -H 'Authorization: Username bob' $BASE_URL/subreddits/GleamRocks/posts -d 'title=Signed Post by Bob' -d 'content=$ENCODED_POST_CONTENT' -d 'signature=$ENCODED_SIGNATURE'"
RESPONSE=$(curl -s -X POST -H "Authorization: Username bob" "$BASE_URL/subreddits/GleamRocks/posts" \
  -d "title=Signed Post by Bob" \
  -d "content=$ENCODED_POST_CONTENT" \
  -d "signature=$ENCODED_SIGNATURE")
echo $RESPONSE | jq
POST_ID_SIGNED=$(echo $RESPONSE | jq -r .post_id)
echo -e "${GREEN}Captured Signed Post ID: $POST_ID_SIGNED${NC}"
sleep $LONG_DELAY

# 6. Verify Post Content (by fetching feed or specific post)
print_header "6. Verifying Bob's Signed Post"
print_request "Fetching Alice's feed to see Bob's post (server verifies signature on retrieval)..."
print_command "curl -s -H 'Authorization: Username alice' $BASE_URL/users/alice/feed"
curl -s -H "Authorization: Username alice" "$BASE_URL/users/alice/feed" | jq
echo -e "${YELLOW}\nObserve that the server should indicate if the signature is valid or not.${NC}"
sleep $LONG_DELAY

# 7. Get User Public Key (Optional, to show it's stored)
print_header "7. Get User Public Key (Bob)"
print_request "Fetching Bob's public key from the server..."
print_command "curl -s $BASE_URL/users/bob/public_key"
curl -s "$BASE_URL/users/bob/public_key" | jq
sleep $DELAY

echo -e "\n${GREEN}Signed Posts Demo completed successfully!${NC}"