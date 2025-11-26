import api/router
import gleam/bool
import gleam/dict
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/set
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import mist
import models.{
  type CommentId, type DirectMessage, type EngineMessage,
  type PerformanceMetrics, type Post, type PostId, type SubredditId,
  type Username, type VoteType, Downvote, RefreshEngineMetrics, Upvote,
}
import wisp
import wisp/wisp_mist

const log_info = True

pub fn get_public_key(
  state: models.EngineState,
  username: Username,
  reply_to: process.Subject(Result(Option(models.PublicKeyRsa2048), String)),
) -> models.EngineState {
  printi("Requesting public key for user: " <> username)
  case dict.get(state.users, username) {
    Ok(user) -> {
      process.send(reply_to, Ok(user.public_key))
    }
    Error(_) -> {
      process.send(reply_to, Error("User not found"))
    }
  }
  state
}

pub fn search_subreddits(
  state: models.EngineState,
  query: String,
  reply_to: process.Subject(List(#(SubredditId, String))),
) -> models.EngineState {
  printi("Searching subreddits for query: " <> query)
  // Perform search and retrieve matching subreddits
  let results =
    dict.filter(state.subreddits, fn(_, subreddit) {
      string.contains(subreddit.name, query)
    })
    |> dict.to_list()
    |> list.map(fn(t) { #(t.0, { t.1 }.description) })
  process.send(reply_to, results)
  state
}

pub fn search_users(
  state: models.EngineState,
  query: String,
  reply_to: process.Subject(List(Username)),
) -> models.EngineState {
  printi("Searching users for query: " <> query)
  // Perform search and retrieve matching users
  let results =
    dict.filter(state.users, fn(username, _) {
      string.contains(username, query)
    })
    |> dict.to_list()
    |> list.map(fn(t) { t.0 })
  process.send(reply_to, results)
  state
}

pub fn refresh_engine_metrics(state: models.EngineState) -> models.EngineState {
  let simulation_checkpoint_time = timestamp.system_time()
  // Update metrics timestamps
  let updated_metrics =
    models.PerformanceMetrics(
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
  models.EngineState(..state, metrics: updated_metrics)
}

pub fn get_engine_metrics(
  state: models.EngineState,
  reply_to: process.Subject(PerformanceMetrics),
) -> models.EngineState {
  printi("Requesting engine performance metrics")
  process.send(reply_to, state.metrics)
  state
}

pub fn get_subreddit_member_count(
  state: models.EngineState,
  subreddit_id: SubredditId,
  reply_to: process.Subject(Result(Int, String)),
) -> models.EngineState {
  printi("Requesting member count for r/" <> subreddit_id)
  // Retrieve subreddit and count subscribers
  let member_count = case dict.get(state.subreddits, subreddit_id) {
    Ok(subreddit) -> Ok(set.size(subreddit.subscribers))
    Error(_) -> Error("Subreddit not found")
  }
  process.send(reply_to, member_count)
  state
}

pub fn get_karma(
  state: models.EngineState,
  sender_username: Username,
  username: Username,
  reply_to: process.Subject(Result(Int, String)),
) -> models.EngineState {
  printi(sender_username <> " is requesting karma for " <> username)

  case dict.has_key(state.users, sender_username) {
    False -> {
      process.send(reply_to, Error("Invalid user"))
      state
    }
    True -> {
      // Retrieve user's upvotes and downvotes
      case dict.get(state.users, username) {
        Ok(user) -> {
          let user_upvotes = int.to_float(user.upvotes)
          let user_downvotes = int.to_float(user.downvotes)
          // Calculate karma based on upvotes and downvotes
          let karma =
            user_upvotes *. 1.2 -. user_downvotes *. 0.7 |> float.round
          process.send(reply_to, Ok(karma))
          state
        }
        Error(_) -> {
          process.send(reply_to, Error("User not found"))
          state
        }
      }
    }
  }
}

pub fn vote_post(
  state: models.EngineState,
  username: Username,
  subreddit_id: SubredditId,
  post_id: PostId,
  vote: VoteType,
  reply_to: process.Subject(Result(String, String)),
) -> models.EngineState {
  printi(username <> " is voting in r/" <> subreddit_id)

  case dict.has_key(state.users, username) {
    False -> {
      process.send(reply_to, Error("Invalid user"))
      state
    }
    True -> {
      // Check if subreddit exists
      case dict.get(state.subreddits, subreddit_id) {
        Error(_) -> {
          printi("⚠ Subreddit r/" <> subreddit_id <> " not found for voting")
          process.send(reply_to, Error("Subreddit not found"))
          state
        }
        Ok(subreddit) -> {
          // Find the post to vote on
          let post_opt =
            list.find(subreddit.posts, fn(post) { post.id == post_id })

          case post_opt {
            Error(_) -> {
              printi("⚠ Post not found in r/" <> subreddit_id <> " for voting")
              process.send(reply_to, Error("Post not found"))
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
                                  models.Post(
                                    ..post,
                                    downvote: post.downvote + 1,
                                  )
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
              let updated_users = case
                dict.get(state.users, found_post.author)
              {
                Ok(_) -> {
                  dict.upsert(state.users, found_post.author, fn(user_op) {
                    case user_op {
                      Some(user) ->
                        case vote {
                          Upvote ->
                            models.User(..user, upvotes: user.upvotes + 1)
                          Downvote ->
                            models.User(..user, downvotes: user.downvotes + 1)
                        }
                      None ->
                        user_op
                        |> option.unwrap(
                          models.User(
                            username: found_post.author,
                            upvotes: 0,
                            public_key: None,
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
              process.send(reply_to, Ok("Voted successfully"))
              models.EngineState(
                ..state,
                subreddits: updated_subreddits,
                users: updated_users,
                metrics: models.PerformanceMetrics(
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
  }
}

pub fn create_post_with_reply(
  state: models.EngineState,
  username: Username,
  subreddit_id: SubredditId,
  signature: Option(String),
  content: String,
  title: String,
  reply_to: process.Subject(Result(PostId, String)),
) -> models.EngineState {
  printi(username <> " is creating post in r/" <> subreddit_id)

  case dict.has_key(state.users, username) {
    False -> {
      process.send(reply_to, Error("Invalid user"))
      state
    }

    True ->
      case dict.get(state.subreddits, subreddit_id) {
        Error(_) -> {
          printi(
            "⚠ Subreddit r/" <> subreddit_id <> " not found for post creation",
          )
          process.send(reply_to, Error("Subreddit not found"))
          state
        }
        Ok(_) -> {
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
              signature: signature,
            )

          // Send the post_id back to the requester
          process.send(reply_to, Ok(new_post.id))

          // Add the post to the subreddit
          let assert Ok(existing_subreddit) =
            dict.get(state.subreddits, subreddit_id)
          let updated_subreddit =
            models.Subreddit(
              ..existing_subreddit,
              posts: list.prepend(existing_subreddit.posts, new_post),
            )
          let updated_subreddits =
            dict.insert(state.subreddits, subreddit_id, updated_subreddit)

          models.EngineState(
            ..state,
            subreddits: updated_subreddits,
            metrics: models.PerformanceMetrics(
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
      }
  }
}

pub fn send_direct_message(
  state: models.EngineState,
  from_username: Username,
  to_username: Username,
  content: String,
  reply_to: process.Subject(Result(String, String)),
) -> models.EngineState {
  printi(from_username <> " is sending DM to " <> to_username)

  case dict.has_key(state.users, from_username) {
    False -> {
      process.send(reply_to, Error("Invalid user"))
      state
    }
    True -> {
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
      case success {
        True -> process.send(reply_to, Ok("Sent DM successfully"))
        False -> process.send(reply_to, Error("Recipient not found"))
      }

      models.EngineState(
        ..state,
        users: updated_users,
        metrics: models.PerformanceMetrics(
          ..state.metrics,
          total_messages: state.metrics.total_messages
            + bool.lazy_guard(
              when: success,
              return: fn() { 1 },
              otherwise: fn() { 0 },
            ),
        ),
      )
    }
  }
}

pub fn get_direct_messages(
  state: models.EngineState,
  username: Username,
  reply_to: process.Subject(Result(List(DirectMessage), String)),
) -> models.EngineState {
  printi(username <> " is fetching their direct messages")

  // Retrieve user's inbox
  case dict.get(state.users, username) {
    Ok(user) -> {
      actor.send(reply_to, Ok(user.inbox))
      state
    }
    Error(_) -> {
      printi("⚠ User " <> username <> " not found for fetching messages")
      actor.send(reply_to, Error("Invalid user"))
      state
    }
  }
}

pub fn get_feed(
  state: models.EngineState,
  username: Username,
  reply_to: process.Subject(Result(List(#(SubredditId, Post)), String)),
) -> models.EngineState {
  // Get user's subscribed subreddits
  let result = case dict.get(state.users, username) {
    Ok(user) -> {
      // Aggregate posts from subscribed subreddits (first 5 from each)
      let feed_posts =
        user.subscribed_subreddits
        |> set.to_list
        |> list.map(fn(subreddit_id) {
          case dict.get(state.subreddits, subreddit_id) {
            Ok(subreddit) ->
              subreddit.posts
              |> list.take(5)
              |> list.map(fn(post) { #(subreddit.name, post) })
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
  state: models.EngineState,
  username: Username,
  subreddit_id: SubredditId,
  post_id: PostId,
  parent_comment_id: CommentId,
  content: String,
  reply_to: process.Subject(Result(CommentId, String)),
) -> models.EngineState {
  printi(username <> " is replying to a comment in r/" <> subreddit_id)

  case dict.has_key(state.users, username) {
    False -> {
      process.send(reply_to, Error("Invalid user"))
      state
    }
    True -> {
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
      case success {
        True -> process.send(reply_to, Ok(new_comment.id))
        False -> process.send(reply_to, Error("Failed to comment on comment"))
      }

      models.EngineState(
        ..state,
        subreddits: updated_subreddits,
        metrics: models.PerformanceMetrics(
          ..state.metrics,
          total_comments: state.metrics.total_comments
            + bool.lazy_guard(
              when: success,
              return: fn() { 1 },
              otherwise: fn() { 0 },
            ),
        ),
      )
    }
  }
}

pub fn comment_on_post(
  state: models.EngineState,
  username: Username,
  subreddit_id: SubredditId,
  post_id: PostId,
  content: String,
  reply_to: process.Subject(Result(CommentId, String)),
) -> models.EngineState {
  printi(username <> " is commenting on a post in r/" <> subreddit_id)

  case dict.has_key(state.users, username) {
    False -> {
      process.send(reply_to, Error("Invalid user"))
      state
    }
    True -> {
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
      case success {
        True -> process.send(reply_to, Ok(new_comment.id))
        False -> process.send(reply_to, Error("Failed to comment on post"))
      }

      models.EngineState(
        ..state,
        subreddits: updated_subreddits,
        metrics: models.PerformanceMetrics(
          ..state.metrics,
          total_comments: state.metrics.total_comments
            + bool.lazy_guard(
              when: success,
              return: fn() { 1 },
              otherwise: fn() { 0 },
            ),
        ),
      )
    }
  }
}

pub fn leave_subreddit(
  state: models.EngineState,
  username: Username,
  subreddit_name: SubredditId,
  reply_to: process.Subject(Result(String, String)),
) -> models.EngineState {
  printi(username <> " is leaving subreddit " <> subreddit_name)

  case dict.get(state.users, username) {
    Error(_) -> {
      process.send(reply_to, Error("User not found"))
      state
    }
    Ok(user) -> {
      let updated_user =
        models.User(
          ..user,
          subscribed_subreddits: set.delete(
            user.subscribed_subreddits,
            subreddit_name,
          ),
        )
      let updated_users = dict.insert(state.users, username, updated_user)

      case dict.get(state.subreddits, subreddit_name) {
        Error(_) -> {
          process.send(reply_to, Error("Subreddit not found"))
          models.EngineState(..state, users: updated_users)
        }
        Ok(subreddit) -> {
          let updated_subreddit =
            models.Subreddit(
              ..subreddit,
              subscribers: set.delete(subreddit.subscribers, username),
            )
          let updated_subreddits =
            dict.insert(state.subreddits, subreddit_name, updated_subreddit)

          let success =
            updated_users != state.users
            || updated_subreddits != state.subreddits
          case success {
            True -> process.send(reply_to, Ok("Left subreddit successfully"))
            False -> process.send(reply_to, Error("Failed to leave subreddit"))
          }

          models.EngineState(
            ..state,
            users: updated_users,
            subreddits: updated_subreddits,
          )
        }
      }
    }
  }
}

pub fn join_subreddit(
  state: models.EngineState,
  username: Username,
  subreddit_name: SubredditId,
  reply_to: process.Subject(Result(String, String)),
) -> models.EngineState {
  printi(username <> " is joining r/" <> subreddit_name)

  case dict.get(state.users, username) {
    Error(_) -> {
      process.send(reply_to, Error("User not found"))
      state
    }
    Ok(user) -> {
      // Add subreddit to user's subscriptions
      let updated_user =
        models.User(
          ..user,
          subscribed_subreddits: set.insert(
            user.subscribed_subreddits,
            subreddit_name,
          ),
        )
      let updated_users = dict.insert(state.users, username, updated_user)

      // Add user to subreddit's subscriber list
      case dict.get(state.subreddits, subreddit_name) {
        Error(_) -> {
          process.send(reply_to, Error("Subreddit not found"))
          models.EngineState(..state, users: updated_users)
        }
        Ok(subreddit) -> {
          let updated_subreddit =
            models.Subreddit(
              ..subreddit,
              subscribers: set.insert(subreddit.subscribers, username),
            )
          let updated_subreddits =
            dict.insert(state.subreddits, subreddit_name, updated_subreddit)

          let success =
            updated_users != state.users
            || updated_subreddits != state.subreddits
          case success {
            True -> process.send(reply_to, Ok("Joined subreddit successfully"))
            False -> process.send(reply_to, Error("Failed to join subreddit"))
          }
          models.EngineState(
            ..state,
            users: updated_users,
            subreddits: updated_subreddits,
          )
        }
      }
    }
  }
}

pub fn create_subreddit(
  state: models.EngineState,
  username: Username,
  name: SubredditId,
  description: String,
  reply_to: process.Subject(Result(String, String)),
) -> models.EngineState {
  case dict.has_key(state.users, username) {
    False -> {
      process.send(reply_to, Error("Invalid user"))
      state
    }
    True -> {
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
          process.send(reply_to, Error("Subreddit exists"))
          state.subreddits
        }

        Error(_) -> {
          printi("✓ Created subreddit r/" <> name)
          process.send(reply_to, Ok("Subreddit created successfully"))
          dict.insert(state.subreddits, name, new_subreddit)
        }
      }

      models.EngineState(..state, subreddits: updated_subreddits)
    }
  }
}

pub fn register_user(
  state: models.EngineState,
  username: Username,
  public_key: Option(models.PublicKeyRsa2048),
  reply_to: process.Subject(Bool),
) -> models.EngineState {
  // Create new user with default values
  let new_user =
    models.User(
      username: username,
      upvotes: 0,
      downvotes: 0,
      subscribed_subreddits: set.new(),
      inbox: [],
      public_key: public_key,
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

  models.EngineState(
    ..state,
    users: updated_users,
    metrics: models.PerformanceMetrics(
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

pub fn main() -> Nil {
  wisp.configure_logger()

  printi("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
  printi("       Reddit Engine Starting Up")
  printi("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

  // Initialize and start the actor with named subject
  let assert Ok(engine_actor) =
    actor.new_with_initialiser(1000, fn(self_sub) {
      models.EngineState(
        self_subject: self_sub,
        users: dict.new(),
        subreddits: dict.new(),
        metrics: models.PerformanceMetrics(
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
    |> actor.on_message(engine_message_handler)
    |> actor.start

  process.send(engine_actor.data, RefreshEngineMetrics)
  printi("✓ Reddit engine actor started")

  // Start web server
  let assert Ok(_) =
    wisp_mist.handler(
      fn(req) { router.handle_request(req, engine_actor.data) },
      wisp.random_string(64),
    )
    |> mist.new
    |> mist.bind("0.0.0.0")
    |> mist.port(8080)
    |> mist.start

  printi("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
  printi("  Engine ready - waiting for messages")
  printi("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

  process.sleep_forever()
  Nil
}

pub fn engine_message_handler(
  state: models.EngineState,
  message: EngineMessage,
) -> actor.Next(models.EngineState, EngineMessage) {
  // Route incoming messages to appropriate handler functions
  case message {
    models.UserRegister(username:, reply_to:, public_key:) ->
      actor.continue(register_user(state, username, public_key, reply_to))
    models.CreateSubreddit(username:, name:, description:, reply_to:) ->
      actor.continue(create_subreddit(
        state,
        username,
        name,
        description,
        reply_to,
      ))
    models.JoinSubreddit(username:, subreddit_name:, reply_to:) ->
      actor.continue(join_subreddit(state, username, subreddit_name, reply_to))
    models.LeaveSubreddit(username:, subreddit_name:, reply_to:) ->
      actor.continue(leave_subreddit(state, username, subreddit_name, reply_to))
    models.CommentOnPost(
      username:,
      subreddit_id:,
      post_id:,
      content:,
      reply_to:,
    ) ->
      actor.continue(comment_on_post(
        state,
        username,
        subreddit_id,
        post_id,
        content,
        reply_to,
      ))
    models.CommentOnComment(
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
    models.GetFeed(username:, reply_to:) ->
      actor.continue(get_feed(state, username, reply_to))
    models.GetDirectMessages(username:, reply_to:) ->
      actor.continue(get_direct_messages(state, username, reply_to))
    models.SendDirectMessage(
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
    models.CreatePostWithReply(
      username:,
      subreddit_id:,
      signature:,
      content:,
      title:,
      reply_to:,
    ) ->
      actor.continue(create_post_with_reply(
        state,
        username,
        subreddit_id,
        signature,
        content,
        title,
        reply_to,
      ))
    models.VotePost(subreddit_id:, username:, post_id:, vote:, reply_to:) ->
      actor.continue(vote_post(
        state,
        username,
        subreddit_id,
        post_id,
        vote,
        reply_to,
      ))
    models.GetKarma(sender_username:, username:, reply_to:) ->
      actor.continue(get_karma(state, sender_username, username, reply_to))
    models.GetSubredditMemberCount(subreddit_id:, reply_to:) ->
      actor.continue(get_subreddit_member_count(state, subreddit_id, reply_to))
    models.GetEngineMetrics(reply_to:) ->
      actor.continue(get_engine_metrics(state, reply_to))
    models.RefreshEngineMetrics -> actor.continue(refresh_engine_metrics(state))
    models.SearchSubreddits(query:, reply_to:) ->
      actor.continue(search_subreddits(state, query, reply_to))
    models.SearchUsers(query:, reply_to:) ->
      actor.continue(search_users(state, query, reply_to))
    models.GetPublicKey(username:, reply_to:) ->
      actor.continue(get_public_key(state, username, reply_to))
  }
}
