import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/atom
import gleam/erlang/charlist.{type Charlist}
import gleam/erlang/process
import gleam/float
import gleam/http.{Get, Post}
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/set
import gleam/time/duration
import gleam/time/timestamp
import middleware
import mist
import models.{
  type CommentId, type DirectMessage, type Post, type PostId, type Subreddit,
  type SubredditId, type User, type Username, type VoteType, Downvote, Upvote,
}
import wisp
import wisp/wisp_mist

const log_info = True

pub fn main() -> Nil {
  wisp.configure_logger()

  printi("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
  printi("       Reddit Engine Starting Up")
  printi("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

  // Create a static name from atom for consistent distributed addressing
  let engine_name = atom_to_name(atom.create("reddit_engine"))

  // Initialize and start the actor with named subject
  let assert Ok(engine_actor) =
    actor.new_with_initialiser(1000, fn(self_sub) {
      EngineState(
        self_subject: self_sub,
        users: dict.new(),
        subreddits: dict.new(),
        metrics: PerformanceMetrics(
          total_users: 0,
          total_posts: 0,
          total_comments: 0,
          total_votes: 0,
          total_messages: 0,
          simulation_start_time: timestamp.system_time(),
          simulation_checkpoint_time: timestamp.system_time(),
          posts_per_second: 0.0,
          messages_per_second: 0.0,
        ),
      )
      |> actor.initialised
      |> actor.returning(self_sub)
      |> Ok
    })
    |> actor.named(engine_name)
    |> actor.on_message(engine_message_handler)
    |> actor.start

  process.send(engine_actor.data, RefreshEngineMetrics)
  printi("✓ Reddit engine actor started")

  // Start distributed Erlang with longnames
  net_kernel_start(charlist.from_string("reddit_engine"))
  set_cookie("reddit_engine", "secret")
  printi("✓ Started distributed Erlang node")

  // Register globally so it's accessible from other nodes
  let global_reg_result = register_global("reddit_engine", engine_actor.pid)
  case global_reg_result {
    Ok(_) -> printi("✓ Reddit engine registered globally!")
    Error(msg) -> printi("✗ Global registration failed: " <> msg)
  }

  io.print("\nGlobal names: ")
  echo list_global_names()

  printi("\nConnected nodes:")
  echo list_nodes()

  printi("\nCurrent cookie:")
  echo get_cookie_erlang()

  // Start web server
  let assert Ok(_) =
    wisp_mist.handler(
      fn(req) { handle_request(req, engine_actor.data) },
      wisp.random_string(64),
    )
    |> mist.new
    |> mist.port(8080)
    |> mist.start

  printi("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
  printi("  Engine ready - waiting for messages")
  printi("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

  process.sleep_forever()
  Nil
}

pub fn handle_request(
  req: wisp.Request,
  engine_inbox: process.Subject(EngineMessage),
) -> wisp.Response {
  use req <- middleware.middleware(req)
  case wisp.path_segments(req) {
    [] -> wisp.ok() |> wisp.html_body("<h1>Reddit Engine running.</h1>")

    // POST /register
    // Registers a new user.
    // Body: "username"
    ["register"] -> {
      use <- wisp.require_method(req, Post)
      use formdata <- wisp.require_form(req)

      let username = case list.key_find(formdata.values, "username") {
        Error(_) -> ""
        Ok(d) -> d
      }

      case username {
        "" -> wisp.bad_request("Invalid username")

        _ -> {
          let result =
            process.call(engine_inbox, 1000, fn(r) { UserRegister(username, r) })

          case result {
            True -> wisp.ok() |> wisp.html_body("User registered successfully")
            False -> wisp.response(409) |> wisp.html_body("User exists")
          }
        }
      }
    }

    // POST /create/subreddit
    // Creates a new subreddit.
    // Body: "title", "description"
    ["create", "subreddit"] -> {
      use <- wisp.require_method(req, Post)
      use formdata <- wisp.require_form(req)

      let title = case list.key_find(formdata.values, "title") {
        Error(_) -> ""
        Ok(d) -> d
      }

      let description = case list.key_find(formdata.values, "description") {
        Error(_) -> ""
        Ok(d) -> d
      }

      case title {
        "" -> wisp.bad_request("Invalid title")

        _ -> {
          let result =
            process.call(engine_inbox, 1000, fn(r) {
              CreateSubreddit(title, description, r)
            })

          case result {
            True ->
              wisp.ok() |> wisp.html_body("Subreddit created successfully")
            False -> wisp.response(409) |> wisp.html_body("Subreddit exists")
          }
        }
      }
    }

    // GET /feed/{username}
    // Gets a user's feed.
    ["feed", username] -> {
      use <- wisp.require_method(req, Get)
      let result =
        process.call(engine_inbox, 1000, fn(r) { GetFeed(username, r) })

      case result {
        Ok(posts) -> {
          let posts_to_json = fn(posts: List(Post)) -> String {
            json.object([
              #(
                "posts",
                json.array(
                  list.map(posts, fn(post) {
                    [
                      #("title", json.string(post.title)),
                      #("content", json.string(post.content)),
                      #("author", json.string(post.author)),
                      #(
                        "comments",
                        json.array(dict.values(post.comments), fn(comment) {
                          json.object([
                            #("content", json.string(comment.content)),
                            #("author", json.string(comment.author)),
                            #("upvote", json.int(comment.upvote)),
                            #("downvote", json.int(comment.downvote)),
                            #(
                              "timestamp",
                              json.float(
                                comment.timestamp |> timestamp.to_unix_seconds,
                              ),
                            ),
                          ])
                        }),
                      ),
                      #("upvote", json.int(post.upvote)),
                      #("downvote", json.int(post.downvote)),
                      #(
                        "timestamp",
                        json.float(post.timestamp |> timestamp.to_unix_seconds),
                      ),
                    ]
                  }),
                  of: json.object,
                ),
              ),
            ])
            |> json.to_string
          }

          wisp.json_response(posts_to_json(posts), 200)
        }

        Error(msg) -> wisp.not_found() |> wisp.html_body(msg)
      }
    }

    // POST /join/subreddit
    // Joins a subreddit.
    // Body: "username", "subreddit"
    ["join", "subreddit"] -> {
      use <- wisp.require_method(req, Post)
      use formdata <- wisp.require_form(req)
      let username = case list.key_find(formdata.values, "username") {
        Error(_) -> ""
        Ok(d) -> d
      }
      let subreddit = case list.key_find(formdata.values, "subreddit") {
        Error(_) -> ""
        Ok(d) -> d
      }
      case username, subreddit {
        "", _ -> wisp.bad_request("Invalid username")
        _, "" -> wisp.bad_request("Invalid subreddit")
        _, _ -> {
          let result =
            process.call(engine_inbox, 1000, fn(r) {
              JoinSubreddit(username, subreddit, r)
            })
          case result {
            True -> wisp.ok() |> wisp.html_body("Joined subreddit successfully")
            False ->
              wisp.response(409) |> wisp.html_body("Failed to join subreddit")
          }
        }
      }
    }

    // POST /leave/subreddit
    // Leaves a subreddit.
    // Body: "username", "subreddit"
    ["leave", "subreddit"] -> {
      use <- wisp.require_method(req, Post)
      use formdata <- wisp.require_form(req)
      let username = case list.key_find(formdata.values, "username") {
        Error(_) -> ""
        Ok(d) -> d
      }
      let subreddit = case list.key_find(formdata.values, "subreddit") {
        Error(_) -> ""
        Ok(d) -> d
      }
      case username, subreddit {
        "", _ -> wisp.bad_request("Invalid username")
        _, "" -> wisp.bad_request("Invalid subreddit")
        _, _ -> {
          let result =
            process.call(engine_inbox, 1000, fn(r) {
              LeaveSubreddit(username, subreddit, r)
            })
          case result {
            True -> wisp.ok() |> wisp.html_body("Left subreddit successfully")
            False ->
              wisp.response(409) |> wisp.html_body("Failed to leave subreddit")
          }
        }
      }
    }

    // POST /comment/post
    // Comments on a post.
    // Body: "username", "subreddit", "post_id", "content"
    ["comment", "post"] -> {
      use <- wisp.require_method(req, Post)
      use formdata <- wisp.require_form(req)
      let username = case list.key_find(formdata.values, "username") {
        Error(_) -> ""
        Ok(d) -> d
      }
      let subreddit = case list.key_find(formdata.values, "subreddit") {
        Error(_) -> ""
        Ok(d) -> d
      }
      let post_id = case list.key_find(formdata.values, "post_id") {
        Error(_) -> ""
        Ok(d) -> d
      }
      let content = case list.key_find(formdata.values, "content") {
        Error(_) -> ""
        Ok(d) -> d
      }
      case username, subreddit, post_id, content {
        "", _, _, _ -> wisp.bad_request("Invalid username")
        _, "", _, _ -> wisp.bad_request("Invalid subreddit")
        _, _, "", _ -> wisp.bad_request("Invalid post_id")
        _, _, _, "" -> wisp.bad_request("Invalid content")
        _, _, _, _ -> {
          case bit_array.base64_decode(post_id) {
            Ok(b) -> {
              let post_id_b = models.Uuid(value: b)
              let result =
                process.call(engine_inbox, 1000, fn(r) {
                  CommentOnPost(username, subreddit, post_id_b, content, r)
                })
              case result {
                True ->
                  wisp.ok() |> wisp.html_body("Commented on post successfully")
                False ->
                  wisp.response(409)
                  |> wisp.html_body("Failed to comment on post")
              }
            }
            Error(_) -> wisp.bad_request("Invalid post_id")
          }
        }
      }
    }

    // POST /comment/comment
    // Replies to a comment.
    // Body: "username", "subreddit", "post_id", "parent_comment_id", "content"
    ["comment", "comment"] -> {
      use <- wisp.require_method(req, Post)
      use formdata <- wisp.require_form(req)
      let username = case list.key_find(formdata.values, "username") {
        Error(_) -> ""
        Ok(d) -> d
      }
      let subreddit = case list.key_find(formdata.values, "subreddit") {
        Error(_) -> ""
        Ok(d) -> d
      }
      let post_id = case list.key_find(formdata.values, "post_id") {
        Error(_) -> ""
        Ok(d) -> d
      }
      let parent_comment_id = case
        list.key_find(formdata.values, "parent_comment_id")
      {
        Error(_) -> ""
        Ok(d) -> d
      }
      let content = case list.key_find(formdata.values, "content") {
        Error(_) -> ""
        Ok(d) -> d
      }
      case username, subreddit, post_id, parent_comment_id, content {
        "", _, _, _, _ -> wisp.bad_request("Invalid username")
        _, "", _, _, _ -> wisp.bad_request("Invalid subreddit")
        _, _, "", _, _ -> wisp.bad_request("Invalid post_id")
        _, _, _, "", _ -> wisp.bad_request("Invalid parent_comment_id")
        _, _, _, _, "" -> wisp.bad_request("Invalid content")
        _, _, _, _, _ -> {
          case
            bit_array.base64_decode(post_id),
            bit_array.base64_decode(parent_comment_id)
          {
            Ok(a), Ok(b) -> {
              let post_id_b = models.Uuid(value: a)
              let parent_comment_id_b = models.Uuid(value: b)

              let result =
                process.call(engine_inbox, 1000, fn(r) {
                  CommentOnComment(
                    username,
                    subreddit,
                    post_id_b,
                    parent_comment_id_b,
                    content,
                    r,
                  )
                })
              case result {
                True ->
                  wisp.ok()
                  |> wisp.html_body("Commented on comment successfully")
                False ->
                  wisp.response(409)
                  |> wisp.html_body("Failed to comment on comment")
              }
            }

            Ok(_), Error(_) -> wisp.bad_request("Invalid parent_comment_id")

            Error(_), Ok(_) -> wisp.bad_request("Invalid post_id")

            Error(_), Error(_) ->
              wisp.bad_request("Invalid parent_comment_id and post_id")
          }
        }
      }
    }

    // POST /vote
    // Votes on a post.
    // Body: "username", "subreddit", "post_id", "vote" ("upvote" or "downvote")
    ["vote"] -> {
      use <- wisp.require_method(req, Post)
      use formdata <- wisp.require_form(req)
      let username = case list.key_find(formdata.values, "username") {
        Error(_) -> ""
        Ok(d) -> d
      }
      let subreddit = case list.key_find(formdata.values, "subreddit") {
        Error(_) -> ""
        Ok(d) -> d
      }
      let post_id = case list.key_find(formdata.values, "post_id") {
        Error(_) -> ""
        Ok(d) -> d
      }
      let vote = case list.key_find(formdata.values, "vote") {
        Error(_) -> ""
        Ok(d) -> d
      }
      case username, subreddit, post_id, vote {
        "", _, _, _ -> wisp.bad_request("Invalid username")
        _, "", _, _ -> wisp.bad_request("Invalid subreddit")
        _, _, "", _ -> wisp.bad_request("Invalid post_id")
        _, _, _, "" -> wisp.bad_request("Invalid vote")
        _, _, _, _ -> {
          let vote_type = case vote {
            "upvote" -> Upvote
            "downvote" -> Downvote
            _ -> Upvote
          }
          case bit_array.base64_decode(post_id) {
            Ok(d) -> {
              let post_id_b = models.Uuid(value: d)

              let result =
                process.call(engine_inbox, 1000, fn(r) {
                  VotePost(subreddit, username, post_id_b, vote_type, r)
                })
              case result {
                True -> wisp.ok() |> wisp.html_body("Voted successfully")
                False -> wisp.response(409) |> wisp.html_body("Failed to vote")
              }
            }
            Error(_) -> wisp.bad_request("Invalid post id")
          }
        }
      }
    }

    // POST /dm
    // Sends a direct message.
    // Body: "from", "to", "content"
    ["dm"] -> {
      use <- wisp.require_method(req, Post)
      use formdata <- wisp.require_form(req)
      let from = case list.key_find(formdata.values, "from") {
        Error(_) -> ""
        Ok(d) -> d
      }
      let to = case list.key_find(formdata.values, "to") {
        Error(_) -> ""
        Ok(d) -> d
      }
      let content = case list.key_find(formdata.values, "content") {
        Error(_) -> ""
        Ok(d) -> d
      }
      case from, to, content {
        "", _, _ -> wisp.bad_request("Invalid from")
        _, "", _ -> wisp.bad_request("Invalid to")
        _, _, "" -> wisp.bad_request("Invalid content")
        _, _, _ -> {
          let result =
            process.call(engine_inbox, 1000, fn(r) {
              SendDirectMessage(from, to, content, r)
            })
          case result {
            True -> wisp.ok() |> wisp.html_body("Sent DM successfully")
            False -> wisp.response(409) |> wisp.html_body("Failed to send DM")
          }
        }
      }
    }

    // POST /create/post
    // Creates a new post.
    // Body: "username", "subreddit", "title", "content"
    ["create", "post"] -> {
      use <- wisp.require_method(req, Post)
      use formdata <- wisp.require_form(req)
      let username = case list.key_find(formdata.values, "username") {
        Error(_) -> ""
        Ok(d) -> d
      }
      let subreddit = case list.key_find(formdata.values, "subreddit") {
        Error(_) -> ""
        Ok(d) -> d
      }
      let title = case list.key_find(formdata.values, "title") {
        Error(_) -> ""
        Ok(d) -> d
      }
      let content = case list.key_find(formdata.values, "content") {
        Error(_) -> ""
        Ok(d) -> d
      }
      case username, subreddit, title, content {
        "", _, _, _ -> wisp.bad_request("Invalid username")
        _, "", _, _ -> wisp.bad_request("Invalid subreddit")
        _, _, "", _ -> wisp.bad_request("Invalid title")
        _, _, _, "" -> wisp.bad_request("Invalid content")
        _, _, _, _ -> {
          let post_id =
            process.call(engine_inbox, 1000, fn(r) {
              CreatePostWithReply(
                username: username,
                subreddit_id: subreddit,
                title: title,
                content: content,
                reply_to: r,
              )
            })
          let models.Uuid(value: post_id_bits) = post_id
          let post_id_string = bit_array.base64_encode(post_id_bits, True)
          wisp.response(201)
          |> wisp.html_body(post_id_string)
        }
      }
    }

    // GET /dms/{username}
    // Gets a user's direct messages.
    ["dms", username] -> {
      use <- wisp.require_method(req, Get)
      let dms =
        process.call(engine_inbox, 1000, fn(r) {
          GetDirectMessages(username, r)
        })

      let dms_to_json = fn(dms: List(DirectMessage)) -> String {
        json.object([
          #(
            "dms",
            json.array(
              list.map(dms, fn(dm) {
                [
                  #("from", json.string(dm.from)),
                  #("to", json.string(dm.to)),
                  #("content", json.string(dm.content)),
                  #(
                    "timestamp",
                    json.float(dm.timestamp |> timestamp.to_unix_seconds),
                  ),
                ]
              }),
              of: json.object,
            ),
          ),
        ])
        |> json.to_string
      }
      wisp.json_response(dms_to_json(dms), 200)
    }

    // GET /karma/{username}
    // Gets a user's karma.
    ["karma", username] -> {
      use <- wisp.require_method(req, Get)
      let karma =
        process.call(engine_inbox, 1000, fn(r) {
          GetKarma("api_user", username, r)
        })

      wisp.ok() |> wisp.html_body(int.to_string(karma))
    }

    // GET /subreddit/members/{subreddit_id}
    // Gets the member count of a subreddit.
    ["subreddit", "members", subreddit_id] -> {
      use <- wisp.require_method(req, Get)
      let count =
        process.call(engine_inbox, 1000, fn(r) {
          GetSubredditMemberCount(subreddit_id, r)
        })

      wisp.ok() |> wisp.html_body(int.to_string(count))
    }

    // GET /metrics
    // Gets the engine's performance metrics.
    ["metrics"] -> {
      use <- wisp.require_method(req, Get)
      let metrics =
        process.call(engine_inbox, 1000, fn(r) { GetEngineMetrics(r) })

      let metrics_to_json = fn(m: PerformanceMetrics) -> String {
        json.object([
          #("total_users", json.int(m.total_users)),
          #("total_posts", json.int(m.total_posts)),
          #("total_comments", json.int(m.total_comments)),
          #("total_votes", json.int(m.total_votes)),
          #("total_messages", json.int(m.total_messages)),
          #(
            "simulation_start_time",
            json.float(m.simulation_start_time |> timestamp.to_unix_seconds),
          ),
          #(
            "simulation_checkpoint_time",
            json.float(
              m.simulation_checkpoint_time |> timestamp.to_unix_seconds,
            ),
          ),
          #("posts_per_second", json.float(m.posts_per_second)),
          #("messages_per_second", json.float(m.messages_per_second)),
        ])
        |> json.to_string
      }
      wisp.json_response(metrics_to_json(metrics), 200)
    }

    _ -> wisp.not_found()
  }
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
  UserRegister(username: Username, reply_to: process.Subject(Bool))
  CreateSubreddit(
    name: SubredditId,
    description: String,
    reply_to: process.Subject(Bool),
  )
  JoinSubreddit(
    username: Username,
    subreddit_name: SubredditId,
    reply_to: process.Subject(Bool),
  )
  LeaveSubreddit(
    username: Username,
    subreddit_name: SubredditId,
    reply_to: process.Subject(Bool),
  )
  CreatePostWithReply(
    username: Username,
    subreddit_id: SubredditId,
    content: String,
    title: String,
    reply_to: process.Subject(PostId),
  )
  CommentOnPost(
    username: Username,
    subreddit_id: SubredditId,
    post_id: PostId,
    content: String,
    reply_to: process.Subject(Bool),
  )
  CommentOnComment(
    username: Username,
    subreddit_id: SubredditId,
    post_id: PostId,
    parent_comment_id: CommentId,
    content: String,
    reply_to: process.Subject(Bool),
  )
  VotePost(
    subreddit_id: SubredditId,
    username: Username,
    post_id: PostId,
    vote: VoteType,
    reply_to: process.Subject(Bool),
  )
  GetFeed(
    username: Username,
    reply_to: process.Subject(Result(List(Post), String)),
  )
  GetDirectMessages(
    username: Username,
    reply_to: process.Subject(List(DirectMessage)),
  )
  SendDirectMessage(
    from_username: Username,
    to_username: Username,
    content: String,
    reply_to: process.Subject(Bool),
  )
  GetKarma(
    sender_username: Username,
    username: Username,
    reply_to: process.Subject(Int),
  )
  GetSubredditMemberCount(
    subreddit_id: SubredditId,
    reply_to: process.Subject(Int),
  )
  GetEngineMetrics(reply_to: process.Subject(PerformanceMetrics))
  RefreshEngineMetrics
}

pub fn engine_message_handler(
  state: EngineState,
  message: EngineMessage,
) -> actor.Next(EngineState, EngineMessage) {
  // Route incoming messages to appropriate handler functions
  case message {
    UserRegister(username:, reply_to:) ->
      actor.continue(register_user(state, username, reply_to))
    CreateSubreddit(name:, description:, reply_to:) ->
      actor.continue(create_subreddit(state, name, description, reply_to))
    JoinSubreddit(username:, subreddit_name:, reply_to:) ->
      actor.continue(join_subreddit(state, username, subreddit_name, reply_to))
    LeaveSubreddit(username:, subreddit_name:, reply_to:) ->
      actor.continue(leave_subreddit(state, username, subreddit_name, reply_to))
    CommentOnPost(username:, subreddit_id:, post_id:, content:, reply_to:) ->
      actor.continue(comment_on_post(
        state,
        username,
        subreddit_id,
        post_id,
        content,
        reply_to,
      ))
    CommentOnComment(
      username: username,
      subreddit_id: subreddit_id,
      post_id: post_id,
      parent_comment_id: parent_comment_id,
      content: content,
      reply_to: reply_to,
    ) ->
      actor.continue(comment_on_comment(
        state,
        username,
        subreddit_id,
        post_id,
        parent_comment_id,
        content,
        reply_to,
      ))
    GetFeed(username:, reply_to:) ->
      actor.continue(get_feed(state, username, reply_to))
    GetDirectMessages(username:, reply_to:) ->
      actor.continue(get_direct_messages(state, username, reply_to))
    SendDirectMessage(
      from_username: from_username,
      to_username: to_username,
      content: content,
      reply_to: reply_to,
    ) ->
      actor.continue(send_direct_message(
        state,
        from_username,
        to_username,
        content,
        reply_to,
      ))
    CreatePostWithReply(username:, subreddit_id:, content:, title:, reply_to:) ->
      actor.continue(create_post_with_reply(
        state,
        username,
        subreddit_id,
        content,
        title,
        reply_to,
      ))
    VotePost(subreddit_id:, username:, post_id:, vote:, reply_to:) ->
      actor.continue(vote_post(
        state,
        username,
        subreddit_id,
        post_id,
        vote,
        reply_to,
      ))
    GetKarma(sender_username:, username:, reply_to:) ->
      actor.continue(get_karma(state, sender_username, username, reply_to))
    GetSubredditMemberCount(subreddit_id:, reply_to:) ->
      actor.continue(get_subreddit_member_count(state, subreddit_id, reply_to))
    GetEngineMetrics(reply_to:) ->
      actor.continue(get_engine_metrics(state, reply_to))
    RefreshEngineMetrics -> actor.continue(refresh_engine_metrics(state))
  }
}

pub fn refresh_engine_metrics(state: EngineState) -> EngineState {
  let simulation_checkpoint_time = timestamp.system_time()
  // Update metrics timestamps
  let updated_metrics =
    PerformanceMetrics(
      ..state.metrics,
      simulation_checkpoint_time: simulation_checkpoint_time,
      posts_per_second: int.to_float(state.metrics.total_posts)
        /. duration.to_seconds(timestamp.difference(
          state.metrics.simulation_start_time,
          simulation_checkpoint_time,
        ))
        |> float.to_precision(3),
      messages_per_second: int.to_float(state.metrics.total_messages)
        /. duration.to_seconds(timestamp.difference(
          state.metrics.simulation_start_time,
          simulation_checkpoint_time,
        ))
        |> float.to_precision(3),
    )
  process.send_after(state.self_subject, 2000, RefreshEngineMetrics)
  EngineState(..state, metrics: updated_metrics)
}

pub fn get_engine_metrics(
  state: EngineState,
  reply_to: process.Subject(PerformanceMetrics),
) -> EngineState {
  printi("Requesting engine performance metrics")
  process.send(reply_to, state.metrics)
  state
}

pub fn get_subreddit_member_count(
  state: EngineState,
  subreddit_id: SubredditId,
  reply_to: process.Subject(Int),
) -> EngineState {
  printi("Requesting member count for r/" <> subreddit_id)
  // Retrieve subreddit and count subscribers
  let member_count = case dict.get(state.subreddits, subreddit_id) {
    Ok(subreddit) -> set.size(subreddit.subscribers)
    Error(_) -> 0
  }
  process.send(reply_to, member_count)
  state
}

pub fn get_karma(
  state: EngineState,
  sender_username: Username,
  username: Username,
  reply_to: process.Subject(Int),
) -> EngineState {
  printi(sender_username <> " is requesting karma for " <> username)
  // Retrieve user's upvotes and downvotes
  let user_upvotes =
    case dict.get(state.users, username) {
      Ok(user) -> user.upvotes
      Error(_) -> 0
    }
    |> int.to_float
  let user_downvotes =
    case dict.get(state.users, username) {
      Ok(user) -> user.downvotes
      Error(_) -> 0
    }
    |> int.to_float
  // Calculate karma based on upvotes and downvotes
  let karma = user_upvotes *. 1.2 -. user_downvotes *. 0.7 |> float.round
  process.send(reply_to, karma)
  state
}

pub fn vote_post(
  state: EngineState,
  username: Username,
  subreddit_id: SubredditId,
  post_id: PostId,
  vote: VoteType,
  reply_to: process.Subject(Bool),
) -> EngineState {
  printi(username <> " is voting in r/" <> subreddit_id)

  // Check if subreddit exists
  case dict.get(state.subreddits, subreddit_id) {
    Error(_) -> {
      printi("⚠ Subreddit r/" <> subreddit_id <> " not found for voting")
      process.send(reply_to, False)
      state
    }
    Ok(subreddit) -> {
      // Find the post to vote on
      let post_opt = list.find(subreddit.posts, fn(post) { post.id == post_id })

      case post_opt {
        Error(_) -> {
          printi("⚠ Post not found in r/" <> subreddit_id <> " for voting")
          process.send(reply_to, False)
          state
        }
        Ok(found_post) -> {
          // Update the post's upvote/downvote count in the subreddit
          let updated_subreddits =
            dict.upsert(state.subreddits, subreddit_id, fn(sub_op) {
              case sub_op {
                Some(subreddit) -> {
                  let updated_posts =
                    list.map(subreddit.posts, fn(post) {
                      case post.id == post_id {
                        True ->
                          case vote {
                            Upvote ->
                              models.Post(..post, upvote: post.upvote + 1)
                            Downvote ->
                              models.Post(..post, downvote: post.downvote + 1)
                          }
                        False -> post
                      }
                    })
                  models.Subreddit(..subreddit, posts: updated_posts)
                }
                None -> subreddit
              }
            })

          // Update the author's karma (upvote/downvote count)
          let updated_users = case dict.get(state.users, found_post.author) {
            Ok(_) -> {
              dict.upsert(state.users, found_post.author, fn(user_op) {
                case user_op {
                  Some(user) ->
                    case vote {
                      Upvote -> models.User(..user, upvotes: user.upvotes + 1)
                      Downvote ->
                        models.User(..user, downvotes: user.downvotes + 1)
                    }
                  None ->
                    user_op
                    |> option.unwrap(
                      models.User(
                        username: found_post.author,
                        upvotes: 0,
                        downvotes: 0,
                        subscribed_subreddits: set.new(),
                        inbox: [],
                      ),
                    )
                }
              })
            }
            Error(_) -> {
              printi("⚠ Post author " <> found_post.author <> " not found")
              state.users
            }
          }
          process.send(reply_to, True)
          EngineState(
            ..state,
            subreddits: updated_subreddits,
            users: updated_users,
            metrics: PerformanceMetrics(
              ..state.metrics,
              total_votes: state.metrics.total_votes
                + bool.lazy_guard(
                  when: updated_subreddits == state.subreddits,
                  return: fn() { 0 },
                  otherwise: fn() { 1 },
                ),
            ),
          )
        }
      }
    }
  }
}

pub fn create_post_with_reply(
  state: EngineState,
  username: Username,
  subreddit_id: SubredditId,
  content: String,
  title: String,
  reply_to: process.Subject(PostId),
) -> EngineState {
  printi(username <> " is creating post in r/" <> subreddit_id)

  // Generate a unique ID and create the new post
  let new_post =
    models.Post(
      id: models.uuid_gen(),
      title: title,
      content: content,
      author: username,
      comments: dict.new(),
      upvote: 0,
      downvote: 0,
      timestamp: timestamp.system_time(),
    )

  // Send the post_id back to the requester
  process.send(reply_to, new_post.id)

  // Add the post to the subreddit
  let updated_subreddits =
    dict.upsert(state.subreddits, subreddit_id, fn(subreddit_op) {
      case subreddit_op {
        Some(subreddit) ->
          models.Subreddit(
            ..subreddit,
            posts: list.prepend(subreddit.posts, new_post),
          )
        None -> {
          printi(
            "⚠ Subreddit r/" <> subreddit_id <> " not found for post creation",
          )
          models.Subreddit(
            name: subreddit_id,
            description: "",
            subscribers: set.new(),
            posts: [new_post],
          )
        }
      }
    })

  EngineState(
    ..state,
    subreddits: updated_subreddits,
    metrics: PerformanceMetrics(
      ..state.metrics,
      total_posts: state.metrics.total_posts
        + bool.lazy_guard(
          when: updated_subreddits == state.subreddits,
          return: fn() { 0 },
          otherwise: fn() { 1 },
        ),
    ),
  )
}

pub fn send_direct_message(
  state: EngineState,
  from_username: Username,
  to_username: Username,
  content: String,
  reply_to: process.Subject(Bool),
) -> EngineState {
  printi(from_username <> " is sending DM to " <> to_username)

  // Create the message with timestamp
  let new_message =
    models.DirectMessage(
      from: from_username,
      to: to_username,
      content: content,
      timestamp: timestamp.system_time(),
    )

  // Add message to recipient's inbox
  let updated_users = case dict.get(state.users, to_username) {
    Ok(_) -> {
      dict.upsert(state.users, to_username, fn(user_op) {
        let assert Some(user) = user_op
        models.User(..user, inbox: list.prepend(user.inbox, new_message))
      })
    }
    Error(_) -> {
      printi("⚠ Recipient user " <> to_username <> " not found")
      state.users
    }
  }

  let success = updated_users != state.users
  process.send(reply_to, success)

  EngineState(
    ..state,
    users: updated_users,
    metrics: PerformanceMetrics(
      ..state.metrics,
      total_messages: state.metrics.total_messages
        + bool.lazy_guard(when: success, return: fn() { 1 }, otherwise: fn() {
          0
        }),
    ),
  )
}

pub fn get_direct_messages(
  state: EngineState,
  username: Username,
  reply_to: process.Subject(List(DirectMessage)),
) -> EngineState {
  printi(username <> " is fetching their direct messages")

  // Retrieve user's inbox
  let user_inbox = case dict.get(state.users, username) {
    Ok(user) -> user.inbox
    Error(_) -> {
      printi("⚠ User " <> username <> " not found for fetching messages")
      []
    }
  }

  // Send inbox to the requesting subject
  actor.send(reply_to, user_inbox)

  state
}

pub fn get_feed(
  state: EngineState,
  username: Username,
  reply_to: process.Subject(Result(List(Post), String)),
) -> EngineState {
  // Get user's subscribed subreddits
  let result = case dict.get(state.users, username) {
    Ok(user) -> {
      // Aggregate posts from subscribed subreddits (top 5 from each)
      let feed_posts =
        user.subscribed_subreddits
        |> set.to_list
        |> list.map(fn(subreddit_id) {
          case dict.get(state.subreddits, subreddit_id) {
            Ok(subreddit) -> subreddit.posts |> list.take(5)
            Error(_) -> []
          }
        })
        |> list.flatten

      printi(
        username
        <> " is requesting their feed, sending "
        <> int.to_string(list.length(feed_posts))
        <> " posts",
      )
      Ok(feed_posts)
    }
    Error(_) -> {
      printi("⚠ User " <> username <> " not found for feed request")
      Error("User not found")
    }
  }

  // Send the result to the requesting subject
  process.send(reply_to, result)

  state
}

pub fn comment_on_comment(
  state: EngineState,
  username: Username,
  subreddit_id: SubredditId,
  post_id: PostId,
  parent_comment_id: CommentId,
  content: String,
  reply_to: process.Subject(Bool),
) -> EngineState {
  printi(username <> " is replying to a comment in r/" <> subreddit_id)

  // Create nested comment with parent reference
  let new_comment =
    models.Comment(
      id: models.uuid_gen(),
      author: username,
      content: content,
      timestamp: timestamp.system_time(),
      upvote: 0,
      downvote: 0,
      parent_id: Some(parent_comment_id),
    )

  // Add comment to the post in the subreddit
  let updated_subreddits =
    dict.upsert(state.subreddits, subreddit_id, fn(sub_op) {
      case sub_op {
        Some(subreddit) -> {
          let updated_posts =
            list.map(subreddit.posts, fn(post) {
              case post.id == post_id {
                False -> post
                True -> {
                  case dict.has_key(post.comments, parent_comment_id) {
                    False -> {
                      printi("⚠ Parent comment not found in post")
                      post
                    }
                    True ->
                      models.Post(
                        ..post,
                        comments: dict.insert(
                          post.comments,
                          new_comment.id,
                          new_comment,
                        ),
                      )
                  }
                }
              }
            })
          models.Subreddit(..subreddit, posts: updated_posts)
        }

        None -> {
          printi(
            "⚠ Subreddit r/" <> subreddit_id <> " not found for commenting",
          )
          sub_op
          |> option.unwrap(
            models.Subreddit(
              name: subreddit_id,
              description: "",
              subscribers: set.new(),
              posts: [],
            ),
          )
        }
      }
    })

  let success = updated_subreddits != state.subreddits
  process.send(reply_to, success)

  EngineState(
    ..state,
    subreddits: updated_subreddits,
    metrics: PerformanceMetrics(
      ..state.metrics,
      total_comments: state.metrics.total_comments
        + bool.lazy_guard(when: success, return: fn() { 1 }, otherwise: fn() {
          0
        }),
    ),
  )
}

pub fn comment_on_post(
  state: EngineState,
  username: Username,
  subreddit_id: SubredditId,
  post_id: PostId,
  content: String,
  reply_to: process.Subject(Bool),
) -> EngineState {
  printi(username <> " is commenting on a post in r/" <> subreddit_id)

  // Create top-level comment (no parent)
  let new_comment =
    models.Comment(
      id: models.uuid_gen(),
      author: username,
      content: content,
      timestamp: timestamp.system_time(),
      upvote: 0,
      downvote: 0,
      parent_id: None,
    )

  // Add comment to the post
  let updated_subreddits =
    dict.upsert(state.subreddits, subreddit_id, fn(sub_op) {
      case sub_op {
        Some(subreddit) -> {
          let updated_posts =
            list.map(subreddit.posts, fn(post) {
              case post.id == post_id {
                False -> post
                True ->
                  models.Post(
                    ..post,
                    comments: dict.insert(
                      post.comments,
                      new_comment.id,
                      new_comment,
                    ),
                  )
              }
            })
          models.Subreddit(..subreddit, posts: updated_posts)
        }

        None -> {
          printi(
            "⚠ Subreddit r/" <> subreddit_id <> " not found for commenting",
          )
          sub_op
          |> option.unwrap(
            models.Subreddit(
              name: subreddit_id,
              description: "",
              subscribers: set.new(),
              posts: [],
            ),
          )
        }
      }
    })

  let success = updated_subreddits != state.subreddits
  process.send(reply_to, success)

  EngineState(
    ..state,
    subreddits: updated_subreddits,
    metrics: PerformanceMetrics(
      ..state.metrics,
      total_comments: state.metrics.total_comments
        + bool.lazy_guard(when: success, return: fn() { 1 }, otherwise: fn() {
          0
        }),
    ),
  )
}

pub fn leave_subreddit(
  state: EngineState,
  username: Username,
  subreddit_name: SubredditId,
  reply_to: process.Subject(Bool),
) -> EngineState {
  printi(username <> " is leaving subreddit " <> subreddit_name)
  let updated_users =
    dict.upsert(state.users, username, fn(user_op) {
      case user_op {
        Some(user) ->
          models.User(
            ..user,
            subscribed_subreddits: set.delete(
              user.subscribed_subreddits,
              subreddit_name,
            ),
          )

        None -> {
          printi("⚠ User " <> username <> " not found for leaving subreddit")
          user_op
          |> option.unwrap(
            models.User(
              username: username,
              upvotes: 0,
              downvotes: 0,
              subscribed_subreddits: set.new(),
              inbox: [],
            ),
          )
        }
      }
    })

  let updated_subreddits =
    dict.upsert(state.subreddits, subreddit_name, fn(sub_op) {
      case sub_op {
        Some(subreddit) ->
          models.Subreddit(
            ..subreddit,
            subscribers: set.delete(subreddit.subscribers, username),
          )

        None -> {
          printi("⚠ Subreddit r/" <> subreddit_name <> " not found for leaving")
          sub_op
          |> option.unwrap(
            models.Subreddit(
              name: subreddit_name,
              description: "",
              subscribers: set.new(),
              posts: [],
            ),
          )
        }
      }
    })

  let success =
    updated_users != state.users || updated_subreddits != state.subreddits
  process.send(reply_to, success)

  EngineState(..state, users: updated_users, subreddits: updated_subreddits)
}

pub fn join_subreddit(
  state: EngineState,
  username: Username,
  subreddit_name: SubredditId,
  reply_to: process.Subject(Bool),
) -> EngineState {
  printi(username <> " is joining r/" <> subreddit_name)

  // Add subreddit to user's subscriptions
  let updated_users =
    dict.upsert(state.users, username, fn(user_op) {
      case user_op {
        Some(user) ->
          models.User(
            ..user,
            subscribed_subreddits: set.insert(
              user.subscribed_subreddits,
              subreddit_name,
            ),
          )

        None -> {
          printi("⚠ User " <> username <> " not found for joining subreddit")
          user_op
          |> option.unwrap(
            models.User(
              username: username,
              upvotes: 0,
              downvotes: 0,
              subscribed_subreddits: set.from_list([subreddit_name]),
              inbox: [],
            ),
          )
        }
      }
    })

  // Add user to subreddit's subscriber list
  let updated_subreddits =
    dict.upsert(state.subreddits, subreddit_name, fn(sub_op) {
      case sub_op {
        Some(subreddit) ->
          models.Subreddit(
            ..subreddit,
            subscribers: set.insert(subreddit.subscribers, username),
          )

        None -> {
          printi("⚠ Subreddit r/" <> subreddit_name <> " not found for joining")
          sub_op
          |> option.unwrap(
            models.Subreddit(
              name: subreddit_name,
              description: "",
              subscribers: set.from_list([username]),
              posts: [],
            ),
          )
        }
      }
    })
  let success =
    updated_users != state.users || updated_subreddits != state.subreddits
  process.send(reply_to, success)
  EngineState(..state, users: updated_users, subreddits: updated_subreddits)
}

pub fn create_subreddit(
  state: EngineState,
  name: SubredditId,
  description: String,
  reply_to: process.Subject(Bool),
) -> EngineState {
  // Create new subreddit with empty subscriber list and posts
  let new_subreddit =
    models.Subreddit(
      name: name,
      description: description,
      subscribers: set.new(),
      posts: [],
    )

  // Check if subreddit already exists to avoid duplicates
  let updated_subreddits = case dict.get(state.subreddits, name) {
    Ok(_) -> {
      printi("⚠ Subreddit r/" <> name <> " already exists")
      process.send(reply_to, False)
      state.subreddits
    }

    Error(_) -> {
      printi("✓ Created subreddit r/" <> name)
      process.send(reply_to, True)
      dict.insert(state.subreddits, name, new_subreddit)
    }
  }

  EngineState(..state, subreddits: updated_subreddits)
}

pub fn register_user(
  state: EngineState,
  username: Username,
  reply_to: process.Subject(Bool),
) -> EngineState {
  // Create new user with default values
  let new_user =
    models.User(
      username: username,
      upvotes: 0,
      downvotes: 0,
      subscribed_subreddits: set.new(),
      inbox: [],
    )

  // Check if user already exists to avoid duplicate registrations
  let updated_users = case dict.has_key(state.users, username) {
    True -> {
      printi("⚠ User " <> username <> " already registered")
      process.send(reply_to, False)
      state.users
    }
    False -> {
      printi("✓ User " <> username <> " registered successfully")
      process.send(reply_to, True)
      dict.insert(state.users, username, new_user)
    }
  }

  EngineState(
    ..state,
    users: updated_users,
    metrics: PerformanceMetrics(
      ..state.metrics,
      total_users: state.metrics.total_users
        + bool.lazy_guard(
          when: updated_users == state.users,
          return: fn() { 0 },
          otherwise: fn() { 1 },
        ),
    ),
  )
}

fn printi(str: String) -> Nil {
  case log_info {
    True -> io.println(str)
    False -> Nil
  }
  Nil
}

// ═══════════════════════════════════════════════════════
// Distributed Erlang FFI Functions
// ═══════════════════════════════════════════════════════

// Convert atom to Name for static naming (no random suffix)
@external(erlang, "distr", "atom_to_name")
fn atom_to_name(atom: atom.Atom) -> process.Name(message)

// Start distributed Erlang with longnames
@external(erlang, "distr", "start_short")
pub fn net_kernel_start(name: Charlist) -> Bool

// Set Erlang cookie for node authentication
@external(erlang, "distr", "set_cookie_erlang")
fn set_cookie_erlang(name: Charlist, cookie: Charlist) -> Bool

// Get current Erlang cookie
@external(erlang, "distr", "get_cookie")
pub fn get_cookie_erlang() -> Charlist

// Ping a remote node to check connectivity
@external(erlang, "distr", "ping")
pub fn ping_erlang(name: Charlist) -> PingResponse

pub type PingResponse {
  Pong
  Pang
}

// Find a process registered on a remote node
@external(erlang, "distr", "whereis_remote")
fn whereis_remote_erlang(
  registered_name: Charlist,
  node_name: Charlist,
) -> Result(process.Pid, atom.Atom)

// Register a process in the global registry
@external(erlang, "distr", "register_global")
fn register_global_erlang(
  name: Charlist,
  pid: process.Pid,
) -> Result(atom.Atom, atom.Atom)

// Find a process in the global registry
@external(erlang, "distr", "whereis_global")
fn whereis_global_erlang(name: Charlist) -> Result(process.Pid, atom.Atom)

// Send message to a named subject on a remote node
@external(erlang, "distr", "send_to_named_subject")
fn send_to_named_subject_erlang(
  pid: process.Pid,
  registered_name: Charlist,
  message: a,
) -> atom.Atom

// List all connected nodes
@external(erlang, "distr", "list_nodes")
fn list_nodes_erlang() -> List(atom.Atom)

// List all globally registered process names
@external(erlang, "distr", "list_global_names")
fn list_global_names_erlang() -> List(atom.Atom)

// ═══════════════════════════════════════════════════════
// Public Wrapper Functions
// ═══════════════════════════════════════════════════════

pub fn register_global(name: String, pid: process.Pid) -> Result(Nil, String) {
  case register_global_erlang(charlist.from_string(name), pid) {
    Ok(_) -> Ok(Nil)
    Error(_) -> Error("Failed to register process globally")
  }
}

pub fn whereis_global(name: String) -> Result(process.Pid, String) {
  case whereis_global_erlang(charlist.from_string(name)) {
    Ok(pid) -> Ok(pid)
    Error(_) -> Error("Process not found in global registry")
  }
}

pub fn list_nodes() -> List(atom.Atom) {
  list_nodes_erlang()
}

pub fn list_global_names() -> List(atom.Atom) {
  list_global_names_erlang()
}

pub fn whereis_remote(
  registered_name: String,
  node_name: String,
) -> Result(process.Pid, String) {
  case
    whereis_remote_erlang(
      charlist.from_string(registered_name),
      charlist.from_string(node_name),
    )
  {
    Ok(pid) -> Ok(pid)
    Error(_) -> Error("Process not found on remote node")
  }
}

pub fn send_to_named_subject(
  pid: process.Pid,
  registered_name: String,
  message: a,
) -> Nil {
  send_to_named_subject_erlang(
    pid,
    charlist.from_string(registered_name),
    message,
  )
  Nil
}

pub fn set_cookie(nodename: String, cookie: String) {
  set_cookie_erlang(
    charlist.from_string(nodename),
    charlist.from_string(cookie),
  )
}

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
