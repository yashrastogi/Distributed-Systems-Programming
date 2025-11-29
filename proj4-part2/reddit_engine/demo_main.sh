#!/bin/bash

BASE_URL="http://192.168.139.3:8080"
DELAY=1
LONG_DELAY=2

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Starting Reddit Engine Demo...${NC}"
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

# 1. Register Users
print_header "1. Registering Users"
print_request "Registering user 'alice'..."
print_command "curl -X POST $BASE_URL/users -d 'username=alice'"
curl -s -X POST "$BASE_URL/users" -d "username=alice" | jq
sleep $DELAY

print_request "Registering user 'bob' with public key..."

PUBKEY=$(cat <<'PEM'
-----BEGIN RSA PUBLIC KEY-----
MIIBCgKCAQEAuNoPQpPCOjd9zkjL2A5k417cPGGrcKS+g2KkzO85BD3IPvDQ6utD
5fWR59Xn9MS5OMaeEWJHGILa4812z709twXIb87mZF4ylUP/3nyBtTPiQCyrDRIy
yoULqp48Zzhv5kTx6mJdEe//u26vG6fCFY3Hf2Fe7TlxfFDTAQ3bdVsJcM+kbP0t
CuPPNazECNGcb2jHGg8lLRFai55v+bbDDa1T2DCCljtWyufdP+ZFRmV9PWc4pPvc
P2EmtP96LXfWzeglct3h2l7GsSxubQRT+aXJ5OTpEl4kO83ScpufUbXloXZUiRoR
ZA4fUxTjEhue5/BfxQxcuED4ysq+KvKqfwIDAQAB
-----END RSA PUBLIC KEY-----


PEM
)
ENCODED_PUBKEY=$(jq -rn --arg x "$PUBKEY" '$x|@uri')

print_command "curl -X POST $BASE_URL/users -d 'username=bob&public_key=$ENCODED_PUBKEY'"
curl -s -X POST "$BASE_URL/users" -d "username=bob&public_key=$ENCODED_PUBKEY" | jq
sleep $LONG_DELAY

# 2. Search Users
print_header "2. Searching Users"
print_request "Searching for users matching 'ali'..."
print_command "curl -s $BASE_URL/search/usernames?q=ali"
curl -s "$BASE_URL/search/usernames?q=ali" | jq
sleep $DELAY

# 3. Create Subreddit
print_header "3. Creating Subreddit"
print_request "Alice creates subreddit 'GleamRocks'..."
print_command "curl -s -X POST -H 'Authorization: Username alice' $BASE_URL/subreddits -d 'title=GleamRocks' -d 'description=Everything about Gleam'"
curl -s -X POST -H "Authorization: Username alice" "$BASE_URL/subreddits" \
  -d "title=GleamRocks" \
  -d "description=Everything about Gleam" | jq
sleep $DELAY

# 4. Search Subreddits
print_header "4. Searching Subreddits"
print_request "Searching for subreddits matching 'Gleam'..."
print_command "curl -s $BASE_URL/search/subreddits?q=Gleam"
curl -s "$BASE_URL/search/subreddits?q=Gleam" | jq
sleep $DELAY

# 5. Join Subreddit
print_header "5. Joining Subreddit"
print_request "Alice joins 'GleamRocks'..."
print_command "curl -s -X PUT -H 'Authorization: Username alice' $BASE_URL/users/alice/subscriptions/GleamRocks"
curl -s -X PUT -H "Authorization: Username alice" "$BASE_URL/users/alice/subscriptions/GleamRocks" | jq
sleep $DELAY

print_request "Bob joins 'GleamRocks'..."
print_command "curl -s -X PUT -H 'Authorization: Username bob' $BASE_URL/users/bob/subscriptions/GleamRocks"
curl -s -X PUT -H "Authorization: Username bob" "$BASE_URL/users/bob/subscriptions/GleamRocks" | jq
sleep $DELAY

# 6. Get Member Count
print_header "6. Checking Member Count"
print_request "Getting member count for 'GleamRocks'..."
print_command "curl -s $BASE_URL/subreddits/GleamRocks/members"
curl -s "$BASE_URL/subreddits/GleamRocks/members" | jq
sleep $DELAY

# 7. Create Post
print_header "7. Creating Post"
print_request "Alice posts in 'GleamRocks'..."
RESPONSE=$(curl -s -X POST -H "Authorization: Username alice" "$BASE_URL/subreddits/GleamRocks/posts" \
  -d "title=Hello World" \
  -d "content=This is the first post!")
print_command "curl -s -X POST -H 'Authorization: Username alice' $BASE_URL/subreddits/GleamRocks/posts -d 'title=Hello World' -d 'content=This is the first post!'"
echo $RESPONSE | jq
# Extract Post ID
POST_ID=$(echo $RESPONSE | jq -r .post_id)
ENCODED_POST_ID=$(jq -rn --arg x "$POST_ID" '$x|@uri')
echo -e "${GREEN}Captured Post ID: $POST_ID${NC}"
sleep $DELAY

print_request "Bob posts in 'GleamRocks' with a signature attached to the post which will be verified each time this post is pulled..."
SIGNATURE=$(cat <<'EOF'
POTjv4SP5VGAvzDxHnKCkYs3Ob3NATc0p58pCbcOilI2VbEYJipFkX0SCboXzHM1c/gQTHa30CWlcgQ6yDyc2rKpotFkJxoIHrkJFOuM6RIm6H68KcEvgXRE1DMJVUbJLFwm+JmAeATnqTxUnrRDyruFJVJcSV2muLn2pOnNdbwDECpdUYsnughO7WA+4YOIK8GPbfa3bpQfIdpQJAo5ohqzVzrGpgy54cAglBLG9xph27JHl6EnTSM6iyNPM/O0h3tBfv1gS5iHAFM1mOgkyS31QrJOyqfiVNggZAeLxCa8fmiHC6z9j1rWHK+8OCPjsR2AGX02xEdEkSyHtYBRaQ==
EOF
)
ENCODED_SIGNATURE=$(jq -rn --arg x "$SIGNATURE" '$x|@uri')
print_command "curl -s -X POST -H 'Authorization: Username bob' $BASE_URL/subreddits/GleamRocks/posts -d 'title=Hello from Bob' -d 'content=This is Bobs first post!' -d 'signature=$ENCODED_SIGNATURE'"
RESPONSE=$(curl -s -X POST -H 'Authorization: Username bob' $BASE_URL/subreddits/GleamRocks/posts -d 'title=Hello from Bob' -d 'content=This is Bobs first post!' -d 'signature='$ENCODED_SIGNATURE)
echo $RESPONSE | jq
sleep $LONG_DELAY

# 8. Vote on Post
print_header "8. Voting on Post"
print_request "Bob upvotes Alice's post..."
print_command "curl -s -X POST -H 'Authorization: Username bob' $BASE_URL/posts/$ENCODED_POST_ID/votes -d 'subreddit=GleamRocks' -d 'vote=upvote'"
curl -s -X POST -H "Authorization: Username bob" "$BASE_URL/posts/$ENCODED_POST_ID/votes" \
  -d "subreddit=GleamRocks" \
  -d "vote=upvote" | jq
sleep $DELAY

# 9. Comment on Post
print_header "9. Commenting on Post"
print_request "Bob comments on Alice's post..."
print_command "curl -s -X POST -H 'Authorization: Username bob' $BASE_URL/subreddits/GleamRocks/posts/$ENCODED_POST_ID/comments -d 'content=Great post Alice!'"
RESPONSE=$(curl -s -X POST -H "Authorization: Username bob" "$BASE_URL/subreddits/GleamRocks/posts/$ENCODED_POST_ID/comments" \
  -d "content=Great post Alice!")
echo $RESPONSE | jq

# Extract Comment ID
COMMENT_ID=$(echo $RESPONSE | jq -r .comment_id)
ENCODED_COMMENT_ID=$(jq -rn --arg x "$COMMENT_ID" '$x|@uri')
echo -e "${GREEN}Captured Comment ID: $COMMENT_ID${NC}"
sleep $DELAY

# 10. Reply to Comment
print_header "10. Replying to Comment"
print_request "Alice replies to Bob's comment..."
print_command "curl -s -X POST -H 'Authorization: Username alice' $BASE_URL/comments/$ENCODED_COMMENT_ID/replies -d 'subreddit=GleamRocks' -d 'post_id=$POST_ID' -d 'content=Thanks Bob!'"
curl -s -X POST -H "Authorization: Username alice" "$BASE_URL/comments/$ENCODED_COMMENT_ID/replies" \
  -d "subreddit=GleamRocks" \
  -d "post_id=$POST_ID" \
  -d "content=Thanks Bob!" | jq
sleep $DELAY

# 11. Get User Public Key
print_header "11. Get User Public Key"
print_request "Fetch Bob's public key if it exists..."
print_command "curl -s $BASE_URL/users/bob/public_key"
curl -s "$BASE_URL/users/bob/public_key" | jq
sleep $DELAY

# 12. Get User Feed
print_header "12. Getting User Feed"
print_request "Fetching Alice's feed, notice that Bob's post has passed signature verification..."
print_command "curl -s -H 'Authorization: Username alice' $BASE_URL/users/alice/feed"
curl -s -H "Authorization: Username alice" "$BASE_URL/users/alice/feed" | jq
sleep $LONG_DELAY

# 13. Send Direct Message
print_header "13. Direct Messaging"
print_request "Bob sends DM to Alice..."
print_command "curl -s -X POST -H 'Authorization: Username bob' $BASE_URL/dms -d 'to=alice' -d 'content=Hey Alice, check out this cool link.'"
curl -s -X POST -H "Authorization: Username bob" "$BASE_URL/dms" \
  -d "to=alice" \
  -d "content=Hey Alice, check out this cool link."
echo "" # Add newline
sleep $DELAY

# 14. Get Direct Messages
print_header "14. Checking DMs"
print_request "Alice checks her DMs..."
print_command "curl -s -H 'Authorization: Username alice' $BASE_URL/users/alice/dms"
curl -s -H "Authorization: Username alice" "$BASE_URL/users/alice/dms" | jq
sleep $DELAY

# 15. Get Karma
print_header "15. Checking Karma"
print_request "Checking Alice's karma..."
print_command "curl -s -H 'Authorization: Username alice' $BASE_URL/users/alice/karma"
curl -s -H "Authorization: Username alice" "$BASE_URL/users/alice/karma" | jq
sleep $DELAY

# 16. Leave Subreddit
print_header "16. Leaving Subreddit"
print_request "Bob leaves 'GleamRocks'..."
print_command "curl -s -X DELETE -H 'Authorization: Username bob' $BASE_URL/users/bob/subscriptions/GleamRocks"
curl -s -X DELETE -H "Authorization: Username bob" "$BASE_URL/users/bob/subscriptions/GleamRocks" | jq
sleep $DELAY

# 17. Get Metrics
print_header "17. Engine Metrics"
print_request "Fetching engine performance metrics..."
print_command "curl -s $BASE_URL/metrics"
curl -s "$BASE_URL/metrics" | jq
sleep $LONG_DELAY

echo -e "\n${GREEN}Demo completed successfully!${NC}"
