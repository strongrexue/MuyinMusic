#ifndef MUSIC_SOURCE_CRYPTO_H_
#define MUSIC_SOURCE_CRYPTO_H_

#include <cstdint>
#include <string>
#include <vector>

namespace muyin {
namespace ms_crypto {

std::vector<uint8_t> Base64Decode(const std::string& text);
std::string Base64Encode(const std::vector<uint8_t>& bytes);

std::string Md5Hex(const std::string& utf8);

// data_base64 / key_base64 / iv_base64 are Base64 strings; returns Base64.
std::string AesEncryptBase64(const std::string& data_base64,
                             const std::string& key_base64,
                             const std::string& iv_base64,
                             const std::string& transformation);

// data_base64 is Base64; public_key_pem is a PEM SubjectPublicKeyInfo.
std::string RsaEncryptBase64(const std::string& data_base64,
                             const std::string& public_key_pem,
                             const std::string& padding);

}  // namespace ms_crypto
}  // namespace muyin

#endif  // MUSIC_SOURCE_CRYPTO_H_
