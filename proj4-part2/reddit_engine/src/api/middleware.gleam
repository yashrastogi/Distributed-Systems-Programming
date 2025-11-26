import gleam/list
import gleam/string
import wisp

pub fn middleware(
  req: wisp.Request,
  handle_request: fn(wisp.Request) -> wisp.Response,
) -> wisp.Response {
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)
  handle_request(req)
}

pub fn require_auth(
  req: wisp.Request,
  next: fn(String) -> wisp.Response,
) -> wisp.Response {
  case list.key_find(req.headers, "authorization") {
    Ok(header) -> {
      case string.split(header, " ") {
        ["Username", username] -> next(username)
        _ -> wisp.response(401)
      }
    }
    Error(_) -> wisp.response(401)
  }
}

pub fn get_form_params(
  formdata: wisp.FormData,
  param_names: List(String),
) -> Result(List(String), Nil) {
  list.try_map(param_names, fn(name) { list.key_find(formdata.values, name) })
}
