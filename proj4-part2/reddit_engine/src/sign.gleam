import gleam/bit_array
import gleam/result.{try}
import rsa_keys

pub fn main() {
  let #(pubkey, prvtkey) = rsa_keys.generate_rsa_keys()

  let result = {
    use signature <- result.try(rsa_keys.sign_message(
      bit_array.from_string("ola mundo"),
      prvtkey,
    ))
    rsa_keys.verify_message(
      message: bit_array.from_string("ola mundo"),
      public_key: pubkey,
      signature: signature,
    )
  }
  echo result
}
