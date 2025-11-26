import gleam/crypto
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/option.{type Option}
import gleam/set.{type Set}
import gleam/time/timestamp.{type Timestamp}

pub type User {
  User(
    username: Username,
    upvotes: Int,
    downvotes: Int,
    subscribed_subreddits: Set(SubredditId),
    inbox: List(DirectMessage),
    public_key: Option(PublicKeyRsa2048),
  )
}

pub type EngineState {
  EngineState(
    self_subject: process.Subject(EngineMessage),
    users: Dict(Username, User),
    subreddits: Dict(SubredditId, Subreddit),
    metrics: PerformanceMetrics,
  )
}

pub type EngineMessage {
  UserRegister(
    username: Username,
    public_key: Option(PublicKeyRsa2048),
    reply_to: process.Subject(Bool),
  )
  CreateSubreddit(
    username: Username,
    name: SubredditId,
    description: String,
    reply_to: process.Subject(Result(String, String)),
  )
  JoinSubreddit(
    username: Username,
    subreddit_name: SubredditId,
    reply_to: process.Subject(Result(String, String)),
  )
  LeaveSubreddit(
    username: Username,
    subreddit_name: SubredditId,
    reply_to: process.Subject(Result(String, String)),
  )
  CreatePostWithReply(
    username: Username,
    subreddit_id: SubredditId,
    signature: Option(String),
    content: String,
    title: String,
    reply_to: process.Subject(Result(PostId, String)),
  )
  CommentOnPost(
    username: Username,
    subreddit_id: SubredditId,
    post_id: PostId,
    content: String,
    reply_to: process.Subject(Result(CommentId, String)),
  )
  CommentOnComment(
    username: Username,
    subreddit_id: SubredditId,
    post_id: PostId,
    parent_comment_id: CommentId,
    content: String,
    reply_to: process.Subject(Result(CommentId, String)),
  )
  VotePost(
    subreddit_id: SubredditId,
    username: Username,
    post_id: PostId,
    vote: VoteType,
    reply_to: process.Subject(Result(String, String)),
  )
  GetFeed(
    username: Username,
    reply_to: process.Subject(Result(List(#(SubredditId, Post)), String)),
  )
  GetDirectMessages(
    username: Username,
    reply_to: process.Subject(Result(List(DirectMessage), String)),
  )
  SendDirectMessage(
    from_username: Username,
    to_username: Username,
    content: String,
    reply_to: process.Subject(Result(String, String)),
  )
  GetPublicKey(
    username: Username,
    reply_to: process.Subject(Result(Option(PublicKeyRsa2048), String)),
  )
  GetKarma(
    sender_username: Username,
    username: Username,
    reply_to: process.Subject(Result(Int, String)),
  )
  GetSubredditMemberCount(
    subreddit_id: SubredditId,
    reply_to: process.Subject(Int),
  )
  GetEngineMetrics(reply_to: process.Subject(PerformanceMetrics))
  RefreshEngineMetrics
  SearchUsers(query: String, reply_to: process.Subject(List(Username)))
  SearchSubreddits(
    query: String,
    reply_to: process.Subject(List(#(SubredditId, String))),
  )
}

pub type PublicKeyRsa2048 {
  PublicKeyRsa2048(key_value: String)
}

pub type DirectMessage {
  DirectMessage(
    from: Username,
    to: Username,
    content: String,
    timestamp: Timestamp,
  )
}

pub type Subreddit {
  Subreddit(
    name: SubredditId,
    description: String,
    subscribers: Set(Username),
    posts: List(Post),
  )
}

pub type SubredditId =
  String

pub type Post {
  Post(
    id: PostId,
    title: String,
    content: String,
    author: Username,
    comments: Dict(CommentId, Comment),
    signature: Option(String),
    upvote: Int,
    downvote: Int,
    timestamp: Timestamp,
  )
}

pub type Comment {
  Comment(
    id: CommentId,
    content: String,
    parent_id: Option(CommentId),
    author: Username,
    timestamp: Timestamp,
    upvote: Int,
    downvote: Int,
  )
}

pub fn uuid_gen() -> Uuid {
  let assert <<a:size(48), _:size(4), b:size(12), _:size(2), c:size(62)>> =
    crypto.strong_random_bytes(16)

  let value = <<a:size(48), 4:size(4), b:size(12), 2:size(2), c:size(62)>>

  Uuid(value: value)
}

pub type Uuid {
  Uuid(value: BitArray)
}

pub type CommentId =
  Uuid

pub type PostId =
  Uuid

pub type VoteType {
  Upvote
  Downvote
}

pub type Username =
  String

pub type PerformanceMetrics {
  PerformanceMetrics(
    total_users: Int,
    total_posts: Int,
    total_comments: Int,
    total_votes: Int,
    total_messages: Int,
    simulation_start_time: timestamp.Timestamp,
    simulation_checkpoint_time: timestamp.Timestamp,
    posts_per_second: Float,
    messages_per_second: Float,
  )
}
