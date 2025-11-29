import api/middleware
import gleam/bit_array
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/http.{Delete, Get, Post, Put}
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/time/timestamp
import gleam/uri
import models.{
  type DirectMessage, type EngineMessage, type PerformanceMetrics, type Post,
  type SubredditId, Downvote, GetEngineMetrics, Upvote,
}
import rsa_keys
import wisp

pub fn handle_request(
  req: wisp.Request,
  engine_inbox: Subject(EngineMessage),
) -> wisp.Response {
  use req <- middleware.middleware(req)
  case wisp.path_segments(req) {
    [] -> wisp.ok() |> wisp.html_body("<h1>Reddit Engine running.</h1>")

    // POST /users
    // Registers a new user.
    // Body: "username"
    ["users"] -> {
      use <- wisp.require_method(req, Post)
      use formdata <- wisp.require_form(req)

      let username_r = list.key_find(formdata.values, "username")
      let public_key_r = list.key_find(formdata.values, "public_key")

      case username_r, public_key_r {
        Ok(username), Ok(public_key) -> {
          let result =
            process.call(engine_inbox, 100_000, fn(r) {
              models.UserRegister(
                username,
                Some(models.PublicKeyRsa2048(public_key)),
                r,
              )
            })

          case result {
            True ->
              wisp.json_response(
                json.to_string(
                  json.object([
                    #("message", json.string("User registered successfully")),
                  ]),
                ),
                201,
              )
            False ->
              wisp.json_response(
                json.to_string(
                  json.object([#("error", json.string("User exists"))]),
                ),
                409,
              )
          }
        }

        Ok(username), _ -> {
          let result =
            process.call(engine_inbox, 100_000, fn(r) {
              models.UserRegister(username, None, r)
            })

          case result {
            True ->
              wisp.json_response(
                json.to_string(
                  json.object([
                    #("message", json.string("User registered successfully")),
                  ]),
                ),
                201,
              )
            False ->
              wisp.json_response(
                json.to_string(
                  json.object([#("error", json.string("User exists"))]),
                ),
                409,
              )
          }
        }

        _, _ -> wisp.bad_request("Form parameters are invalid")
      }
    }

    // POST /subreddits
    // Creates a new subreddit.
    // Headers: Authorization: Username <username>
    // Body: "title", "description"
    ["subreddits"] -> {
      use <- wisp.require_method(req, Post)
      use username <- middleware.require_auth(req)
      use formdata <- wisp.require_form(req)

      case middleware.get_form_params(formdata, ["title", "description"]) {
        Ok([title, description]) -> {
          let result =
            process.call(engine_inbox, 100_000, fn(r) {
              models.CreateSubreddit(username, title, description, r)
            })

          case result {
            Ok(msg) ->
              wisp.json_response(
                json.to_string(
                  json.object([
                    #("message", json.string(msg)),
                  ]),
                ),
                201,
              )
            Error(err) ->
              wisp.json_response(
                json.to_string(json.object([#("error", json.string(err))])),
                400,
              )
          }
        }
        _ -> wisp.bad_request("Form parameters are invalid")
      }
    }

    // GET /users/{username}/feed
    // Gets a user's feed.
    ["users", username, "feed"] -> {
      use <- wisp.require_method(req, Get)
      use auth_user <- middleware.require_auth(req)

      // Validate that the authenticated user is requesting their own feed
      case auth_user == username {
        True -> {
          let feed_result =
            process.call(engine_inbox, 100_000, fn(r) {
              models.GetFeed(username, r)
            })

          case feed_result {
            Ok(posts) -> {
              let posts_to_json = fn(posts: List(#(SubredditId, Post))) -> String {
                json.object([
                  #(
                    "posts",
                    json.array(
                      list.map(posts, fn(post) {
                        let verified = case { post.1 }.signature {
                          Some(signature) -> {
                            let author_public_key = case
                              process.call(engine_inbox, 100_000, fn(r) {
                                models.GetPublicKey({ post.1 }.author, r)
                              })
                            {
                              Ok(Some(public_key)) -> public_key.key_value
                              _ -> ""
                            }

                            rsa_keys.verify_message_with_pem_string(
                              { post.1 }.content |> bit_array.from_string,
                              author_public_key,
                              signature
                                |> bit_array.base64_decode
                                |> result.unwrap(bit_array.from_string("")),
                            )
                            |> result.unwrap(False)
                          }

                          None -> False
                        }

                        [
                          #("subreddit_id", json.string(post.0)),
                          #("title", json.string({ post.1 }.title)),
                          #("content", json.string({ post.1 }.content)),
                          #("signature_verified", json.bool(verified)),
                          #("author", json.string({ post.1 }.author)),
                          #("upvote", json.int({ post.1 }.upvote)),
                          #("downvote", json.int({ post.1 }.downvote)),
                          #(
                            "comments",
                            json.array(
                              dict.values({ post.1 }.comments),
                              fn(comment) {
                                json.object([
                                  #("content", json.string(comment.content)),
                                  #("author", json.string(comment.author)),
                                  #("upvote", json.int(comment.upvote)),
                                  #("downvote", json.int(comment.downvote)),
                                  #(
                                    "timestamp",
                                    json.float(
                                      comment.timestamp
                                      |> timestamp.to_unix_seconds,
                                    ),
                                  ),
                                ])
                              },
                            ),
                          ),
                          #("upvote", json.int({ post.1 }.upvote)),
                          #("downvote", json.int({ post.1 }.downvote)),
                          #(
                            "timestamp",
                            json.float(
                              { post.1 }.timestamp |> timestamp.to_unix_seconds,
                            ),
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

            Error(msg) ->
              wisp.json_response(
                json.to_string(json.object([#("error", json.string(msg))])),
                404,
              )
          }
        }
        False -> wisp.response(403)
      }
    }

    // PUT/DELETE /users/{username}/subscriptions/{subreddit_id}
    // Joins or leaves a subreddit.
    ["users", username, "subscriptions", subreddit_id] -> {
      use auth_user <- middleware.require_auth(req)
      case auth_user == username {
        True -> {
          case req.method {
            Put -> {
              let result =
                process.call(engine_inbox, 100_000, fn(r) {
                  models.JoinSubreddit(username, subreddit_id, r)
                })
              case result {
                Ok(msg) ->
                  wisp.json_response(
                    json.to_string(
                      json.object([
                        #("message", json.string(msg)),
                      ]),
                    ),
                    200,
                  )
                Error(err) ->
                  wisp.json_response(
                    json.to_string(
                      json.object([
                        #("error", json.string(err)),
                      ]),
                    ),
                    400,
                  )
              }
            }
            Delete -> {
              let result =
                process.call(engine_inbox, 100_000, fn(r) {
                  models.LeaveSubreddit(username, subreddit_id, r)
                })
              case result {
                Ok(msg) ->
                  wisp.json_response(
                    json.to_string(
                      json.object([
                        #("message", json.string(msg)),
                      ]),
                    ),
                    200,
                  )
                Error(err) ->
                  wisp.json_response(
                    json.to_string(
                      json.object([
                        #("error", json.string(err)),
                      ]),
                    ),
                    400,
                  )
              }
            }
            _ -> wisp.method_not_allowed([Put, Delete])
          }
        }
        False -> wisp.response(403)
      }
    }

    // POST /subreddits/{subreddit_id}/posts/{post_id}/comments
    // Comments on a post.
    // Body: "content"
    ["subreddits", subreddit_id, "posts", post_id_str, "comments"] -> {
      use <- wisp.require_method(req, Post)
      use username <- middleware.require_auth(req)
      use formdata <- wisp.require_form(req)
      case middleware.get_form_params(formdata, ["content"]) {
        Ok([content]) -> {
          case uri.percent_decode(post_id_str) {
            Ok(post_id_str) -> {
              case bit_array.base64_decode(post_id_str) {
                Ok(b) -> {
                  let post_id_b = models.Uuid(value: b)
                  let result =
                    process.call(engine_inbox, 100_000, fn(r) {
                      models.CommentOnPost(
                        username,
                        subreddit_id,
                        post_id_b,
                        content,
                        r,
                      )
                    })
                  case result {
                    Ok(id) -> {
                      let models.Uuid(value: id_bits) = id
                      let id_str = bit_array.base64_encode(id_bits, True)
                      wisp.json_response(
                        json.to_string(
                          json.object([#("comment_id", json.string(id_str))]),
                        ),
                        201,
                      )
                    }
                    Error(err) ->
                      wisp.json_response(
                        json.to_string(
                          json.object([
                            #("error", json.string(err)),
                          ]),
                        ),
                        400,
                      )
                  }
                }
                Error(_) -> wisp.bad_request("Invalid post_id")
              }
            }

            Error(_) -> wisp.bad_request("Invalid post_id")
          }
        }
        _ -> wisp.bad_request("Form parameters are invalid")
      }
    }

    // POST /comments/{parent_comment_id}/replies
    // Replies to a comment.
    // Body: "subreddit", "post_id", "content"
    ["comments", parent_comment_id_str, "replies"] -> {
      use <- wisp.require_method(req, Post)
      use username <- middleware.require_auth(req)
      use formdata <- wisp.require_form(req)

      case
        middleware.get_form_params(formdata, [
          "subreddit",
          "post_id",
          "content",
        ])
      {
        Ok([subreddit, post_id_str, content]) -> {
          case uri.percent_decode(parent_comment_id_str) {
            Ok(parent_comment_id_str) -> {
              case
                bit_array.base64_decode(post_id_str),
                bit_array.base64_decode(parent_comment_id_str)
              {
                Ok(a), Ok(b) -> {
                  let post_id_b = models.Uuid(value: a)
                  let parent_comment_id_b = models.Uuid(value: b)

                  let result =
                    process.call(engine_inbox, 100_000, fn(r) {
                      models.CommentOnComment(
                        username,
                        subreddit,
                        post_id_b,
                        parent_comment_id_b,
                        content,
                        r,
                      )
                    })
                  case result {
                    Ok(id) -> {
                      let models.Uuid(value: id_bits) = id
                      let id_str = bit_array.base64_encode(id_bits, True)
                      wisp.json_response(
                        json.to_string(
                          json.object([#("comment_id", json.string(id_str))]),
                        ),
                        201,
                      )
                    }
                    Error(err) ->
                      wisp.json_response(
                        json.to_string(
                          json.object([
                            #("error", json.string(err)),
                          ]),
                        ),
                        400,
                      )
                  }
                }

                Ok(_), Error(_) -> wisp.bad_request("Invalid parent_comment_id")

                Error(_), Ok(_) -> wisp.bad_request("Invalid post_id")

                Error(_), Error(_) ->
                  wisp.bad_request("Invalid parent_comment_id and post_id")
              }
            }

            Error(_) -> wisp.bad_request("Invalid parent_comment_id")
          }
        }
        _ -> wisp.bad_request("Form parameters are invalid")
      }
    }

    // POST /posts/{post_id}/votes
    // Votes on a post.
    // Body: "subreddit", "vote" ("upvote" or "downvote")
    ["posts", post_id_str, "votes"] -> {
      use <- wisp.require_method(req, Post)
      use username <- middleware.require_auth(req)
      use formdata <- wisp.require_form(req)
      let subreddit_r = list.key_find(formdata.values, "subreddit")
      let vote_r = list.key_find(formdata.values, "vote")
      case subreddit_r, vote_r {
        Ok(subreddit), Ok(vote) -> {
          let vote_type = case vote {
            "upvote" -> Upvote
            "downvote" -> Downvote
            _ -> Upvote
          }
          case uri.percent_decode(post_id_str) {
            Ok(post_id_str) -> {
              case bit_array.base64_decode(post_id_str) {
                Ok(d) -> {
                  let post_id_b = models.Uuid(value: d)
                  let result =
                    process.call(engine_inbox, 100_000, fn(r) {
                      models.VotePost(
                        subreddit,
                        username,
                        post_id_b,
                        vote_type,
                        r,
                      )
                    })
                  case result {
                    Ok(msg) ->
                      wisp.json_response(
                        json.to_string(
                          json.object([
                            #("message", json.string(msg)),
                          ]),
                        ),
                        200,
                      )
                    Error(err) ->
                      wisp.json_response(
                        json.to_string(
                          json.object([#("error", json.string(err))]),
                        ),
                        400,
                      )
                  }
                }
                Error(_) -> wisp.bad_request("Invalid post id")
              }
            }

            Error(_) -> wisp.bad_request("Invalid post id")
          }
        }

        _, _ -> wisp.bad_request("Form parameters are invalid")
      }
    }

    // POST /dms
    // Sends a direct message.
    // Body: "to", "content"
    ["dms"] -> {
      use <- wisp.require_method(req, Post)
      use from <- middleware.require_auth(req)
      use formdata <- wisp.require_form(req)
      case middleware.get_form_params(formdata, ["to", "content"]) {
        Ok([to, content]) -> {
          let result =
            process.call(engine_inbox, 100_000, fn(r) {
              models.SendDirectMessage(from, to, content, r)
            })
          case result {
            Ok(msg) ->
              wisp.json_response(
                json.to_string(
                  json.object([
                    #("message", json.string(msg)),
                  ]),
                ),
                200,
              )
            Error(err) ->
              wisp.json_response(
                json.to_string(json.object([#("error", json.string(err))])),
                400,
              )
          }
        }
        _ -> wisp.bad_request("Form parameters are invalid")
      }
    }

    // POST /subreddits/{subreddit_id}/posts
    // Creates a new post.
    // Body: "title", "content"
    ["subreddits", subreddit_id, "posts"] -> {
      use <- wisp.require_method(req, Post)
      use username <- middleware.require_auth(req)
      use formdata <- wisp.require_form(req)
      case middleware.get_form_params(formdata, ["title", "content"]) {
        Ok([title, content]) -> {
          let post_id = case
            middleware.get_form_params(formdata, ["signature"])
          {
            Ok([signature]) ->
              process.call(engine_inbox, 100_000, fn(r) {
                models.CreatePostWithReply(
                  username: username,
                  subreddit_id: subreddit_id,
                  title: title,
                  signature: Some(signature),
                  content: content,
                  reply_to: r,
                )
              })

            _ ->
              process.call(engine_inbox, 100_000, fn(r) {
                models.CreatePostWithReply(
                  username: username,
                  subreddit_id: subreddit_id,
                  title: title,
                  signature: None,
                  content: content,
                  reply_to: r,
                )
              })
          }

          case post_id {
            Ok(id) -> {
              let models.Uuid(value: post_id_bits) = id
              let post_id_string = bit_array.base64_encode(post_id_bits, True)
              wisp.json_response(
                json.to_string(
                  json.object([#("post_id", json.string(post_id_string))]),
                ),
                201,
              )
            }
            Error(err) ->
              wisp.json_response(
                json.to_string(json.object([#("error", json.string(err))])),
                400,
              )
          }
        }
        _ -> wisp.bad_request("Form parameters are invalid")
      }
    }

    // GET /users/{username}/dms
    // Gets a user's direct messages.
    ["users", username, "dms"] -> {
      use <- wisp.require_method(req, Get)
      use auth_user <- middleware.require_auth(req)

      case auth_user == username {
        True -> {
          let dms_result =
            process.call(engine_inbox, 100_000, fn(r) {
              models.GetDirectMessages(username, r)
            })

          case dms_result {
            Ok(dms) -> {
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
                            json.float(
                              dm.timestamp |> timestamp.to_unix_seconds,
                            ),
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
            Error(err) ->
              wisp.json_response(
                json.to_string(json.object([#("error", json.string(err))])),
                400,
              )
          }
        }
        False -> wisp.response(403)
      }
    }

    // GET /users/{username}/public_key
    // Gets a user's public key.
    ["users", username, "public_key"] -> {
      use <- wisp.require_method(req, Get)

      let public_key_result =
        process.call(engine_inbox, 100_000, fn(r) {
          models.GetPublicKey(username, r)
        })

      case public_key_result {
        Ok(public_key_option) ->
          case public_key_option {
            Some(public_key) ->
              wisp.json_response(
                json.to_string(
                  json.object([
                    #("public_key", json.string(public_key.key_value)),
                  ]),
                ),
                200,
              )

            None ->
              wisp.json_response(
                json.to_string(
                  json.object([
                    #("error", json.string("User has no public key")),
                  ]),
                ),
                400,
              )
          }

        Error(err) ->
          wisp.json_response(
            json.to_string(json.object([#("error", json.string(err))])),
            400,
          )
      }
    }

    // GET /users/{username}/karma
    // Gets a user's karma.
    ["users", username, "karma"] -> {
      use <- wisp.require_method(req, Get)
      use sender_username <- middleware.require_auth(req)

      let karma_result =
        process.call(engine_inbox, 100_000, fn(r) {
          models.GetKarma(sender_username, username, r)
        })

      case karma_result {
        Ok(karma) ->
          wisp.json_response(
            json.to_string(json.object([#("karma", json.int(karma))])),
            200,
          )
        Error(err) ->
          wisp.json_response(
            json.to_string(json.object([#("error", json.string(err))])),
            400,
          )
      }
    }

    // GET /search/usernames?q={query}
    // Searches for users containing query string.
    ["search", "usernames"] -> {
      use <- wisp.require_method(req, Get)
      case list.key_find(wisp.get_query(req), "q") {
        Ok(query) -> {
          let users =
            process.call(engine_inbox, 100_000, fn(r) {
              models.SearchUsers(query, r)
            })

          wisp.json_response(
            json.to_string(json.array(users, of: json.string)),
            200,
          )
        }

        Error(_) -> wisp.bad_request("Missing query parameter")
      }
    }

    // GET /search/subreddits?q={query}
    // Searches for subreddits containing query string.
    ["search", "subreddits"] -> {
      use <- wisp.require_method(req, Get)
      case list.key_find(wisp.get_query(req), "q") {
        Ok(query) -> {
          let subreddits =
            process.call(engine_inbox, 100_000, fn(r) {
              models.SearchSubreddits(query, r)
            })
          wisp.json_response(
            json.array(subreddits, of: fn(tup: #(SubredditId, String)) {
              json.object([
                #("name", json.string(tup.0)),
                #("description", json.string(tup.1)),
              ])
            })
              |> json.to_string,
            200,
          )
        }

        Error(_) -> wisp.bad_request("Missing query parameter")
      }
    }

    // GET /subreddits/{subreddit_id}/members
    // Gets the member count of a subreddit.
    ["subreddits", subreddit_id, "members"] -> {
      use <- wisp.require_method(req, Get)
      let count =
        process.call(engine_inbox, 100_000, fn(r) {
          models.GetSubredditMemberCount(subreddit_id, r)
        })

      case count {
        Ok(count) ->
          wisp.json_response(
            json.to_string(json.object([#("member_count", json.int(count))])),
            200,
          )

        Error(msg) ->
          wisp.json_response(
            json.to_string(json.object([#("error", json.string(msg))])),
            400,
          )
      }
    }

    // GET /metrics
    // Gets the engine's performance metrics.
    ["metrics"] -> {
      use <- wisp.require_method(req, Get)
      let metrics =
        process.call(engine_inbox, 100_000, fn(r) { GetEngineMetrics(r) })

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
