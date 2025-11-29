import argv
import gleam/bit_array
import gleam/io
import rsa_keys

pub fn main() {
  case argv.load().arguments {
    [content, priv_key] -> {
      let message = bit_array.from_string(content)
      let private_key = priv_key
      let signature =
        rsa_keys.sign_message_with_pem_string(
          message: message,
          private_key_pem: private_key,
        )

      let signature_b64 = case signature {
        Ok(sig) -> bit_array.base64_encode(sig, False)
        Error(_) -> "SIGNING_FAILED"
      }
      io.println(signature_b64)
    }
    _ -> io.println("usage: ./program <content> <priv_key>")
  }
}
