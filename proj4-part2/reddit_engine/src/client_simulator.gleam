import gleam/erlang/process
import gleam/float
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/io
import gleam/list
import gleam/string
import gleam/uri

const total_users = 100_000

const api_host = "localhost"

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
    <> int.to_string(total_users)
    <> " users with realistic behavior patterns\n",
  )

  // Start post tracking actor
  let post_tracker = start_post_tracker()

  run_simulation(post_tracker)
}

pub type PostTrackingMessage {
  AddPost(subreddit: String, post_id: String)
  GetRandomPost(reply_to: process.Subject(Result(#(String, String), Nil)))
}

// Actor to track posts across all users for voting/commenting
fn start_post_tracker() -> process.Subject(PostTrackingMessage) {
  let parent_subject = process.new_subject()

  process.spawn_unlinked(fn() {
    let subject = process.new_subject()
    // Send the subject back to parent
    process.send(parent_subject, subject)
    post_tracker_loop(subject, [])
  })

  // Wait for the subject from the spawned process
  let assert Ok(subject) = process.receive(parent_subject, 1000)
  subject
}

fn post_tracker_loop(
  subject: process.Subject(PostTrackingMessage),
  posts: List(#(String, String)),
) {
  case process.receive(subject, 10) {
    Ok(AddPost(subreddit, post_id)) -> {
      post_tracker_loop(subject, [#(subreddit, post_id), ..posts])
    }
    Ok(GetRandomPost(reply_to)) -> {
      let result = case list.shuffle(posts) |> list.first {
        Ok(post) -> Ok(post)
        Error(_) -> Error(Nil)
      }
      process.send(reply_to, result)
      post_tracker_loop(subject, posts)
    }
    Error(_) -> {
      // Timeout, continue
      post_tracker_loop(subject, posts)
    }
  }
}

fn run_simulation(post_tracker: process.Subject(PostTrackingMessage)) {
  io.println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
  io.println("Phase 1: Setting up Subreddits")
  io.println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

  // Create subreddits
  list.each(subreddits_by_rank, fn(subreddit) {
    let #(name, desc, _) = subreddit
    let _ = create_subreddit(name, desc)
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
    list.range(1, total_users)
    |> list.map(fn(i) {
      let username = "user" <> int.to_string(i)
      let is_power_user = i <= total_users / 10

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
  wait_for_completions(completion_subject, total_users, 0)

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

fn report_engine_metrics() {
  case get_engine_metrics() {
    Ok(metrics_json) -> {
      io.println("Engine Metrics (JSON):")
      io.println(metrics_json)
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
          Ok(post_id) -> {
            process.send(post_tracker, AddPost(subreddit, post_id))
          }

          Error(_) -> Nil
        }

        process.sleep(int.random(300) + 100)
      }

      // 20% Comment on a post
      3 | 4 -> {
        let reply_subject = process.new_subject()
        process.send(post_tracker, GetRandomPost(reply_subject))

        case process.receive(reply_subject, 100) {
          Ok(Ok(#(subreddit, post_id))) -> {
            let _ =
              comment_on_post(
                username,
                subreddit,
                post_id,
                "Great post! Here are my thoughts...",
              )
            process.sleep(int.random(200) + 50)
          }
          _ -> Nil
        }
      }

      // 20% Send direct message
      5 | 6 -> {
        let recipient = "user" <> int.to_string(int.random(total_users) + 1)

        let _ =
          send_direct_message(username, recipient, "Hey! How are you doing?")
        process.sleep(int.random(200) + 50)
      }

      // 20% Vote on posts
      7 | 8 -> {
        let reply_subject = process.new_subject()
        process.send(post_tracker, GetRandomPost(reply_subject))

        case process.receive(reply_subject, 100) {
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
  let body = "username=" <> username
  post_request("/register", body)
}

fn create_subreddit(
  title: String,
  description: String,
) -> Result(String, String) {
  let body = "title=" <> title <> "&description=" <> description
  post_request("/create/subreddit", body)
}

fn join_subreddit(username: String, subreddit: String) -> Result(String, String) {
  let body = "username=" <> username <> "&subreddit=" <> subreddit
  post_request("/join/subreddit", body)
}

fn create_post(
  username: String,
  subreddit: String,
  title: String,
  content: String,
) -> Result(String, String) {
  let body =
    "username="
    <> username
    <> "&subreddit="
    <> subreddit
    <> "&title="
    <> title
    <> "&content="
    <> content

  post_request("/create/post", body)
}

fn comment_on_post(
  username: String,
  subreddit: String,
  post_id: String,
  content: String,
) -> Result(String, String) {
  let body =
    "username="
    <> username
    <> "&subreddit="
    <> subreddit
    <> "&post_id="
    <> uri.percent_encode(post_id)
    <> "&content="
    <> content
  post_request("/comment/post", body)
}

fn vote_post(
  username: String,
  subreddit: String,
  post_id: String,
  vote: String,
) -> Result(String, String) {
  let body =
    "username="
    <> username
    <> "&subreddit="
    <> subreddit
    <> "&post_id="
    <> uri.percent_encode(post_id)
    <> "&vote="
    <> vote
  post_request("/vote", body)
}

fn send_direct_message(
  from: String,
  to: String,
  content: String,
) -> Result(String, String) {
  let body = "from=" <> from <> "&to=" <> to <> "&content=" <> content
  post_request("/dm", body)
}

fn get_feed(username: String) -> Result(String, String) {
  get_request("/feed/" <> username)
}

fn get_subreddit_member_count(subreddit: String) -> Result(Int, String) {
  case get_request("/subreddit/members/" <> subreddit) {
    Ok(body) -> {
      case int.parse(body) {
        Ok(i) -> Ok(i)
        Error(_) -> Error("Failed to parse member count")
      }
    }
    Error(e) -> Error(e)
  }
}

fn get_engine_metrics() -> Result(String, String) {
  get_request("/metrics")
}

fn post_request(path: String, body: String) -> Result(String, String) {
  let req =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_scheme(http.Http)
    |> request.set_host(api_host)
    |> request.set_port(api_port)
    |> request.set_path(path)
    |> request.set_body(body)
    |> request.set_header("content-type", "application/x-www-form-urlencoded")

  case httpc.send(req) {
    Ok(resp) ->
      case resp.status {
        200 | 201 -> Ok(resp.body)
        _ -> Error("Request failed with status " <> int.to_string(resp.status))
      }
    Error(_) -> Error("HTTP request failed")
  }
}

fn get_request(path: String) -> Result(String, String) {
  let req =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_scheme(http.Http)
    |> request.set_host(api_host)
    |> request.set_port(api_port)
    |> request.set_path(path)

  case httpc.send(req) {
    Ok(resp) ->
      case resp.status {
        200 -> Ok(resp.body)
        _ -> Error("Request failed with status " <> int.to_string(resp.status))
      }
    Error(_) -> Error("HTTP request failed")
  }
}
