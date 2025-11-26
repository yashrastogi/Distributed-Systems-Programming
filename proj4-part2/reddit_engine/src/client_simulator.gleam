import gleam/dynamic/decode
import gleam/erlang/process
import gleam/float
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import gleam/uri
import models.{type PerformanceMetrics}

const clients = 9999

const api_host = "192.168.139.3"

const api_port = 8080

// Rank subreddits by expected popularity
const subreddits_by_rank = [
  #("gaming", "Video games and gaming culture", 1),
  #("technology", "Latest in tech", 2),
  #("movies", "Movie discussions and reviews", 3),
  #("gleam", "Gleam programming language", 4),
  #("science", "Scientific discoveries", 5),
  #("functional", "Functional programming discussions", 6),
  #("erlang", "Erlang and BEAM ecosystem", 7),
  #("distributed", "Distributed systems", 8),
]

pub fn main() {
  io.println("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
  io.println("       Reddit Engine Simulator")
  io.println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
  io.println(
    "Simulating "
    <> int.to_string(clients)
    <> " users with realistic behavior patterns\n",
  )

  // Start post tracking actor
  let post_tracker = start_post_tracker()

  run_simulation(post_tracker)
}

pub type PostTrackingMessage {
  AddPost(subreddit: String, post_id: String)
  GetRandomPost(reply_to: process.Subject(Result(#(String, String), Nil)))
  AddComment(subreddit: String, post_id: String, comment_id: String)
  GetRandomComment(
    reply_to: process.Subject(Result(#(String, String, String), Nil)),
  )
}

// Actor to track posts across all users for voting/commenting
fn start_post_tracker() -> process.Subject(PostTrackingMessage) {
  let parent_subject = process.new_subject()

  process.spawn_unlinked(fn() {
    let subject = process.new_subject()
    // Send the subject back to parent
    process.send(parent_subject, subject)
    post_tracker_loop(subject, [], [])
  })

  // Wait for the subject from the spawned process
  let assert Ok(subject) = process.receive(parent_subject, 10_000)
  subject
}

fn post_tracker_loop(
  subject: process.Subject(PostTrackingMessage),
  posts: List(#(String, String)),
  comments: List(#(String, String, String)),
) {
  case process.receive(subject, 10_000) {
    Ok(AddPost(subreddit, post_id)) -> {
      post_tracker_loop(subject, [#(subreddit, post_id), ..posts], comments)
    }
    Ok(GetRandomPost(reply_to)) -> {
      let result = case list.shuffle(posts) |> list.first {
        Ok(post) -> Ok(post)
        Error(_) -> Error(Nil)
      }
      process.send(reply_to, result)
      post_tracker_loop(subject, posts, comments)
    }
    Ok(AddComment(subreddit, post_id, comment_id)) -> {
      post_tracker_loop(subject, posts, [
        #(subreddit, post_id, comment_id),
        ..comments
      ])
    }
    Ok(GetRandomComment(reply_to)) -> {
      let result = case list.shuffle(comments) |> list.first {
        Ok(comment) -> Ok(comment)
        Error(_) -> Error(Nil)
      }
      process.send(reply_to, result)
      post_tracker_loop(subject, posts, comments)
    }
    Error(_) -> {
      // Timeout, continue
      post_tracker_loop(subject, posts, comments)
    }
  }
}

fn run_simulation(post_tracker: process.Subject(PostTrackingMessage)) {
  io.println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
  io.println("Phase 1: Setting up Subreddits")
  io.println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

  // Register admin user for creating subreddits
  let _ = register_user("admin")

  // Create subreddits
  list.each(subreddits_by_rank, fn(subreddit) {
    let #(name, desc, _) = subreddit
    let _ = create_subreddit("admin", name, desc)
    io.println("✓ Created subreddit: " <> name)
  })
  io.println("")
  process.sleep(500)

  io.println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
  io.println("Phase 2: Spawning User Actors")
  io.println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

  let completion_subject = process.new_subject()

  // Spawn user actors - each runs independently
  let user_pids =
    list.range(1, clients)
    |> list.map(fn(i) {
      let username = "user" <> int.to_string(i)
      let is_power_user = i <= clients / 10

      // Spawn each user as a separate process
      let user_pid =
        process.spawn_unlinked(fn() {
          simulate_user(username, is_power_user, post_tracker)

          // Track completion
          process.send(completion_subject, username)
        })

      io.println("✓ Spawned user actor: " <> username)
      user_pid
    })

  io.println("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
  io.println(
    "✓ Spawned " <> int.to_string(list.length(user_pids)) <> " user actors",
  )
  io.println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

  // Let the simulation run for a while
  wait_for_completions(completion_subject, clients, 0)

  // Report subreddit membership distribution
  io.println("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
  io.println("Subreddit Membership Distribution (Zipf)")
  io.println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

  report_membership_distribution()

  io.println("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
  io.println("Engine Performance Metrics")
  io.println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

  report_engine_metrics()

  io.println("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
  io.println("Simulation Complete!")
  io.println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
}

// Helper to format float to a string with a given precision
fn float_to_string(f: Float, precision p: Int) -> String {
  float.to_string(f)
  |> string.split(".")
  |> fn(parts) {
    case parts {
      [i, d] -> i <> "." <> string.slice(d, 0, p)
      _ -> float.to_string(f)
    }
  }
}

// Define a decoder for the PerformanceMetrics
fn performance_metrics_decoder() -> decode.Decoder(PerformanceMetrics) {
  use total_users <- decode.field("total_users", decode.int)
  use total_posts <- decode.field("total_posts", decode.int)
  use total_comments <- decode.field("total_comments", decode.int)
  use total_votes <- decode.field("total_votes", decode.int)
  use total_messages <- decode.field("total_messages", decode.int)
  use posts_per_second <- decode.field("posts_per_second", decode.float)
  use messages_per_second <- decode.field("messages_per_second", decode.float)
  use simulation_start_time <- decode.field(
    "simulation_start_time",
    decode.float,
  )
  use simulation_checkpoint_time <- decode.field(
    "simulation_checkpoint_time",
    decode.float,
  )

  decode.success(models.PerformanceMetrics(
    total_users: total_users,
    total_posts: total_posts,
    total_comments: total_comments,
    total_votes: total_votes,
    total_messages: total_messages,
    simulation_start_time: timestamp.from_unix_seconds(
      simulation_start_time |> float.round,
    ),
    simulation_checkpoint_time: timestamp.from_unix_seconds(
      simulation_checkpoint_time |> float.round,
    ),
    posts_per_second: posts_per_second,
    messages_per_second: messages_per_second,
  ))
}

fn report_engine_metrics() {
  case get_engine_metrics() {
    Ok(metrics_json) -> {
      case json.parse(metrics_json, performance_metrics_decoder()) {
        Ok(metrics) -> {
          // Format and print the metrics in a table
          let longest_label_length =
            ["Users", "Posts", "Comments", "Votes", "Messages"]
            |> list.map(string.length)
            |> list.max(int.compare)
            |> result.unwrap(0)

          let print_row = fn(label: String, value: String) {
            io.println(
              "  "
              <> string.pad_end(label, longest_label_length, " ")
              <> " : "
              <> value,
            )
          }

          print_row("Users", int.to_string(metrics.total_users))
          print_row("Posts", int.to_string(metrics.total_posts))
          print_row("Comments", int.to_string(metrics.total_comments))
          print_row("Votes", int.to_string(metrics.total_votes))
          print_row("Messages", int.to_string(metrics.total_messages))

          io.println("")
          print_row(
            "Posts/sec",
            float_to_string(metrics.posts_per_second, precision: 3),
          )
          print_row(
            "Messages/sec",
            float_to_string(metrics.messages_per_second, precision: 3),
          )
        }
        Error(_) -> {
          io.println("Failed to decode engine metrics JSON.")
          // Fallback to printing the raw JSON
          io.println("Engine Metrics (JSON):")
          io.println(metrics_json)
        }
      }
    }
    Error(_) -> {
      io.println("Could not retrieve engine metrics.")
    }
  }
}

fn report_membership_distribution() {
  list.each(subreddits_by_rank, fn(subreddit) {
    let #(name, _, rank) = subreddit
    case get_subreddit_member_count(name) {
      Ok(count) -> {
        io.println(
          "Rank "
          <> int.to_string(rank)
          <> "  | r/"
          <> name
          <> "\t| Members: "
          <> int.to_string(count),
        )
      }
      Error(_) -> Nil
    }
  })
}

// Wait for all user actors to complete
fn wait_for_completions(
  subject: process.Subject(String),
  total: Int,
  count: Int,
) {
  case process.receive(subject, 120_000) {
    Ok(_username) -> {
      let new_count = count + 1
      case new_count >= total {
        True -> Nil
        False -> wait_for_completions(subject, total, new_count)
      }
    }
    Error(_) -> wait_for_completions(subject, total, count)
  }
}

// Each user actor runs this function independently
fn simulate_user(
  username: String,
  is_power_user: Bool,
  post_tracker: process.Subject(PostTrackingMessage),
) {
  // 1. Register the user
  let _ = register_user(username)
  process.sleep(int.random(100) + 50)

  // 2. Join subreddits
  let num_joins = case is_power_user {
    True -> 6 + int.random(3)
    // Power users join 6-8 subreddits
    False -> 2 + int.random(2)
    // Regular users join 2-3 subreddits
  }

  list.range(1, num_joins)
  |> list.each(fn(_) {
    let subreddit = pick_random_subreddit(is_power_user)
    let _ = join_subreddit(username, subreddit)
    process.sleep(int.random(200) + 100)
  })

  // 3. Simulate online/offline cycles
  let cycles = case is_power_user {
    True -> 5 + int.random(5)
    // Power users: 5-10 cycles
    False -> 2 + int.random(3)
    // Regular users: 2-5 cycles
  }

  list.range(1, cycles)
  |> list.each(fn(cycle) {
    // User comes online
    let online_duration = case is_power_user {
      True -> 2000 + int.random(3000)
      // 2-5 seconds online
      False -> 1000 + int.random(2000)
      // 1-3 seconds online
    }
    io.println("... " <> username <> " going online ...")
    // Perform activities while online
    perform_online_activities(username, is_power_user, cycle, post_tracker)

    // Stay online for a while
    process.sleep(online_duration)

    // User goes offline
    let offline_duration = int.random(1000) + 500
    io.println("... " <> username <> " going offline ...")
    // 0.5-1.5 seconds offline
    process.sleep(offline_duration)
  })

  io.println("✓ " <> username <> " completed simulation")
}

fn perform_online_activities(
  username: String,
  is_power_user: Bool,
  cycle: Int,
  post_tracker: process.Subject(PostTrackingMessage),
) {
  let num_activities = case is_power_user {
    True -> 3 + int.random(7)
    // Power users: 3-10 activities
    False -> 1 + int.random(3)
    // Regular users: 1-4 activities
  }

  list.range(1, num_activities)
  |> list.each(fn(activity_num) {
    let activity_type = int.random(10)

    case activity_type {
      // 30% Create a post
      0 | 1 | 2 -> {
        let subreddit = pick_random_subreddit(is_power_user)
        let is_repost = is_power_user && int.random(5) == 0

        let title = case is_repost {
          True -> "[REPOST] " <> generate_title(cycle * 100 + activity_num)
          False -> generate_title(cycle * 100 + activity_num)
        }

        // Create post and get response with post_id
        case
          create_post(
            username,
            subreddit,
            title,
            generate_content(cycle * 100 + activity_num),
          )
        {
          Ok(response_body) -> {
            let decoder = {
              use id <- decode.field("post_id", decode.string)
              decode.success(id)
            }
            case json.parse(from: response_body, using: decoder) {
              Ok(id) -> process.send(post_tracker, AddPost(subreddit, id))
              Error(_) -> Nil
            }
          }

          Error(_) -> Nil
        }

        process.sleep(int.random(300) + 100)
      }

      // 10% Comment on a post
      3 -> {
        let reply_subject = process.new_subject()
        process.send(post_tracker, GetRandomPost(reply_subject))

        case process.receive(reply_subject, 10_000) {
          Ok(Ok(#(subreddit, post_id))) -> {
            case
              comment_on_post(
                username,
                subreddit,
                post_id,
                "Great post! Here are my thoughts...",
              )
            {
              Ok(response_body) -> {
                let decoder = {
                  use id <- decode.field("comment_id", decode.string)
                  decode.success(id)
                }
                case json.parse(from: response_body, using: decoder) {
                  Ok(id) ->
                    process.send(
                      post_tracker,
                      AddComment(subreddit, post_id, id),
                    )
                  Error(_) -> Nil
                }
              }
              Error(_) -> Nil
            }
            process.sleep(int.random(200) + 50)
          }
          _ -> Nil
        }
      }

      // 10% Reply to a comment
      4 -> {
        let reply_subject = process.new_subject()
        process.send(post_tracker, GetRandomComment(reply_subject))

        case process.receive(reply_subject, 10_000) {
          Ok(Ok(#(subreddit, post_id, comment_id))) -> {
            case
              comment_on_comment(
                username,
                subreddit,
                post_id,
                comment_id,
                "Interesting point! I agree.",
              )
            {
              Ok(response_body) -> {
                let decoder = {
                  use id <- decode.field("comment_id", decode.string)
                  decode.success(id)
                }
                case json.parse(from: response_body, using: decoder) {
                  Ok(id) ->
                    process.send(
                      post_tracker,
                      AddComment(subreddit, post_id, id),
                    )
                  Error(_) -> Nil
                }
              }

              Error(_) -> {
                Nil
              }
            }
            process.sleep(int.random(200) + 50)
          }
          _ -> Nil
        }
      }

      // 20% Send direct message
      5 | 6 -> {
        let recipient = "user" <> int.to_string(int.random(clients) + 1)

        let _ =
          send_direct_message(username, recipient, "Hey! How are you doing?")
        process.sleep(int.random(200) + 50)
      }

      // 20% Vote on posts
      7 | 8 -> {
        let reply_subject = process.new_subject()
        process.send(post_tracker, GetRandomPost(reply_subject))

        case process.receive(reply_subject, 10_000) {
          Ok(Ok(#(subreddit, post_id))) -> {
            let vote = case int.random(2) {
              0 -> "upvote"
              _ -> "downvote"
            }

            let _ = vote_post(username, subreddit, post_id, vote)
            process.sleep(int.random(100) + 50)
          }
          _ -> Nil
        }
      }

      // 10% Get their feed
      _ -> {
        let _ = get_feed(username)
        // Don't wait for reply, just fire and forget
        process.sleep(int.random(100) + 50)
      }
    }
  })
}

fn pick_random_subreddit(is_power_user: Bool) -> String {
  case is_power_user {
    // Power users follow Zipf distribution strictly
    True -> pick_subreddit_zipf()
    False -> {
      // Regular users: 70% Zipf, 30% uniform random
      case int.random(10) < 7 {
        True -> pick_subreddit_zipf()
        False ->
          list.shuffle(subreddits_by_rank)
          |> list.first
          |> fn(r) {
            case r {
              Ok(#(s, _, _)) -> s
              Error(_) -> "gleam"
            }
          }
      }
    }
  }
}

fn generate_title(index: Int) -> String {
  let titles = [
    "Check out this amazing feature!",
    "Discussion: Best practices for ",
    "Help needed with ",
    "TIL: Interesting fact about ",
    "Question about implementation",
    "Sharing my recent project",
    "Performance optimization tips",
    "New release announcement",
  ]

  list.shuffle(titles)
  |> list.first
  |> fn(r) {
    case r {
      Ok(t) -> t <> " #" <> int.to_string(index)
      Error(_) -> "Post #" <> int.to_string(index)
    }
  }
}

fn generate_content(index: Int) -> String {
  "This is the content for post #"
  <> int.to_string(index)
  <> ". Lorem ipsum dolor sit amet, consectetur adipiscing elit."
}

pub fn calculate_zipf_distribution() -> List(Float) {
  let ranks = list.range(1, list.length(subreddits_by_rank))
  // For each subreddit at rank r, the probability weight is 1/r.
  let weights = list.map(ranks, fn(rank) { 1.0 /. int.to_float(rank) })
  // Normalize weights
  let total = list.fold(weights, 0.0, fn(acc, w) { acc +. w })
  // Return normalized weights
  list.map(weights, fn(w) { w /. total })
}

fn pick_subreddit_zipf() -> String {
  let distribution = calculate_zipf_distribution()
  select_by_cumulative_probability(
    subreddits_by_rank,
    distribution,
    float.random(),
    0.0,
  )
}

fn select_by_cumulative_probability(
  subreddits: List(#(String, String, Int)),
  probabilities: List(Float),
  target: Float,
  cumulative: Float,
) -> String {
  case subreddits, probabilities {
    [], _ -> "gleam"
    // Default subreddit
    _, [] -> "gleam"
    // Default subreddit
    [#(name, _, _), ..rest_subs], [p, ..rest_probs] -> {
      let new_cumulative = cumulative +. p
      // Check if target falls within this cumulative range
      case target <=. new_cumulative {
        True -> name
        False ->
          select_by_cumulative_probability(
            rest_subs,
            rest_probs,
            target,
            new_cumulative,
          )
      }
    }
  }
}

// HTTP API Helpers

fn register_user(username: String) -> Result(String, String) {
  let body = "username=" <> uri.percent_encode(username)
  post_request("/users", body, None)
}

fn create_subreddit(
  username: String,
  title: String,
  description: String,
) -> Result(String, String) {
  let body =
    "title="
    <> uri.percent_encode(title)
    <> "&description="
    <> uri.percent_encode(description)
  post_request("/subreddits", body, Some(username))
}

fn join_subreddit(username: String, subreddit: String) -> Result(String, String) {
  put_request(
    "/users/"
      <> uri.percent_encode(username)
      <> "/subscriptions/"
      <> uri.percent_encode(subreddit),
    "",
    Some(username),
  )
}

fn create_post(
  username: String,
  subreddit: String,
  title: String,
  content: String,
) -> Result(String, String) {
  let body =
    "title="
    <> uri.percent_encode(title)
    <> "&content="
    <> uri.percent_encode(content)

  post_request(
    "/subreddits/" <> uri.percent_encode(subreddit) <> "/posts",
    body,
    Some(username),
  )
}

fn comment_on_post(
  username: String,
  subreddit: String,
  post_id: String,
  content: String,
) -> Result(String, String) {
  let body = "content=" <> uri.percent_encode(content)
  post_request(
    "/subreddits/"
      <> uri.percent_encode(subreddit)
      <> "/posts/"
      <> uri.percent_encode(post_id)
      <> "/comments",
    body,
    Some(username),
  )
}

fn comment_on_comment(
  username: String,
  subreddit: String,
  post_id: String,
  parent_comment_id: String,
  content: String,
) -> Result(String, String) {
  let body =
    "subreddit="
    <> uri.percent_encode(subreddit)
    <> "&post_id="
    <> uri.percent_encode(post_id)
    <> "&content="
    <> uri.percent_encode(content)

  post_request(
    "/comments/" <> uri.percent_encode(parent_comment_id) <> "/replies",
    body,
    Some(username),
  )
}

fn vote_post(
  username: String,
  subreddit: String,
  post_id: String,
  vote: String,
) -> Result(String, String) {
  let body =
    "subreddit="
    <> uri.percent_encode(subreddit)
    <> "&vote="
    <> uri.percent_encode(vote)
  post_request(
    "/posts/" <> uri.percent_encode(post_id) <> "/votes",
    body,
    Some(username),
  )
}

fn send_direct_message(
  from: String,
  to: String,
  content: String,
) -> Result(String, String) {
  let body =
    "to="
    <> uri.percent_encode(to)
    <> "&content="
    <> uri.percent_encode(content)
  post_request("/dms", body, Some(from))
}

fn get_feed(username: String) -> Result(String, String) {
  get_request(
    "/users/" <> uri.percent_encode(username) <> "/feed",
    Some(username),
  )
}

fn get_subreddit_member_count(subreddit: String) -> Result(Int, String) {
  case
    get_request(
      "/subreddits/" <> uri.percent_encode(subreddit) <> "/members",
      None,
    )
  {
    Ok(body) -> {
      let decoder = {
        use member_count <- decode.field("member_count", decode.int)
        decode.success(member_count)
      }

      case json.parse(body, decoder) {
        Ok(count) -> Ok(count)
        Error(_) -> Error("Failed to decode member count JSON")
      }
    }
    Error(e) -> Error(e)
  }
}

fn get_engine_metrics() -> Result(String, String) {
  get_request("/metrics", None)
}

fn post_request(
  path: String,
  body: String,
  auth_user: Option(String),
) -> Result(String, String) {
  let req =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_scheme(http.Http)
    |> request.set_host(api_host)
    |> request.set_port(api_port)
    |> request.set_path(path)
    |> request.set_body(body)
    |> request.set_header("content-type", "application/x-www-form-urlencoded")

  let req = case auth_user {
    Some(u) -> request.set_header(req, "authorization", "Username " <> u)
    None -> req
  }

  case httpc.send(req) {
    Ok(resp) ->
      case resp.status {
        200 | 201 -> Ok(resp.body)
        _ ->
          Error(
            "Request failed with status "
            <> int.to_string(resp.status)
            <> " "
            <> resp.body,
          )
      }
    Error(_) -> Error("HTTP request failed")
  }
}

fn get_request(
  path: String,
  auth_user: Option(String),
) -> Result(String, String) {
  let req =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_scheme(http.Http)
    |> request.set_host(api_host)
    |> request.set_port(api_port)
    |> request.set_path(path)

  let req = case auth_user {
    Some(u) -> request.set_header(req, "authorization", "Username " <> u)
    None -> req
  }

  case httpc.send(req) {
    Ok(resp) ->
      case resp.status {
        200 -> Ok(resp.body)
        _ -> Error("Request failed with status " <> int.to_string(resp.status))
      }
    Error(_) -> Error("HTTP request failed")
  }
}

fn put_request(
  path: String,
  body: String,
  auth_user: Option(String),
) -> Result(String, String) {
  let req =
    request.new()
    |> request.set_method(http.Put)
    |> request.set_scheme(http.Http)
    |> request.set_host(api_host)
    |> request.set_port(api_port)
    |> request.set_path(path)
    |> request.set_body(body)
    |> request.set_header("content-type", "application/x-www-form-urlencoded")

  let req = case auth_user {
    Some(u) -> request.set_header(req, "authorization", "Username " <> u)
    None -> req
  }

  case httpc.send(req) {
    Ok(resp) ->
      case resp.status {
        200 | 201 -> Ok(resp.body)
        _ -> Error("Request failed with status " <> int.to_string(resp.status))
      }
    Error(_) -> Error("HTTP request failed")
  }
}
