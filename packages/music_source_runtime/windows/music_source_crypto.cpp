#include "music_source_crypto.h"

#include <algorithm>
#include <cctype>
#include <cstddef>
#include <cstring>
#include <cwchar>
#include <limits>

#include <windows.h>
#include <bcrypt.h>

namespace muyin {
namespace ms_crypto {
namespace {

#ifndef NT_SUCCESS
#define NT_SUCCESS(status) (((NTSTATUS)(status)) >= 0)
#endif

const char kBase64Chars[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

bool IsBase64Value(char c, int* out) {
  if (c >= 'A' && c <= 'Z') { *out = c - 'A'; return true; }
  if (c >= 'a' && c <= 'z') { *out = c - 'a' + 26; return true; }
  if (c >= '0' && c <= '9') { *out = c - '0' + 52; return true; }
  if (c == '+') { *out = 62; return true; }
  if (c == '/') { *out = 63; return true; }
  return false;
}

}  // namespace

std::string Base64Encode(const std::vector<uint8_t>& bytes) {
  std::string out;
  const size_t n = bytes.size();
  out.reserve(((n + 2) / 3) * 4);
  size_t i = 0;
  while (i + 3 <= n) {
    const uint32_t v = (uint32_t(bytes[i]) << 16) |
                       (uint32_t(bytes[i + 1]) << 8) | uint32_t(bytes[i + 2]);
    out.push_back(kBase64Chars[(v >> 18) & 63]);
    out.push_back(kBase64Chars[(v >> 12) & 63]);
    out.push_back(kBase64Chars[(v >> 6) & 63]);
    out.push_back(kBase64Chars[v & 63]);
    i += 3;
  }
  if (n - i == 1) {
    const uint32_t v = uint32_t(bytes[i]) << 16;
    out.push_back(kBase64Chars[(v >> 18) & 63]);
    out.push_back(kBase64Chars[(v >> 12) & 63]);
    out.push_back('=');
    out.push_back('=');
  } else if (n - i == 2) {
    const uint32_t v = (uint32_t(bytes[i]) << 16) |
                       (uint32_t(bytes[i + 1]) << 8);
    out.push_back(kBase64Chars[(v >> 18) & 63]);
    out.push_back(kBase64Chars[(v >> 12) & 63]);
    out.push_back(kBase64Chars[(v >> 6) & 63]);
    out.push_back('=');
  }
  return out;
}

std::vector<uint8_t> Base64Decode(const std::string& text) {
  std::vector<uint8_t> out;
  int accum = 0;
  int bits = 0;
  for (char ch : text) {
    if (ch == '=') break;
    if (ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t') continue;
    int v = 0;
    if (!IsBase64Value(ch, &v)) return std::vector<uint8_t>();
    accum = (accum << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push_back(static_cast<uint8_t>((accum >> bits) & 0xff));
    }
  }
  return out;
}

std::string Md5Hex(const std::string& utf8) {
  BCRYPT_ALG_HANDLE alg = nullptr;
  if (!NT_SUCCESS(BCryptOpenAlgorithmProvider(&alg, BCRYPT_MD5_ALGORITHM,
                                              nullptr, 0))) {
    return std::string();
  }
  std::string result;
  ULONG hash_len = 0;
  ULONG got = 0;
  if (NT_SUCCESS(BCryptGetProperty(alg, BCRYPT_HASH_LENGTH,
                                   reinterpret_cast<PUCHAR>(&hash_len),
                                   sizeof(hash_len), &got, 0)) &&
      hash_len > 0 && hash_len <= 64) {
    BCRYPT_HASH_HANDLE hash = nullptr;
    std::vector<uint8_t> object(256);
    if (NT_SUCCESS(BCryptCreateHash(alg, &hash, object.data(),
                                    static_cast<ULONG>(object.size()), nullptr,
                                    0, 0))) {
      if (NT_SUCCESS(BCryptHashData(hash,
                                    reinterpret_cast<PUCHAR>(
                                        const_cast<char*>(utf8.data())),
                                    static_cast<ULONG>(utf8.size()), 0))) {
        std::vector<uint8_t> digest(hash_len);
        if (NT_SUCCESS(BCryptFinishHash(hash, digest.data(), hash_len, 0))) {
          static const char kHex[] = "0123456789abcdef";
          result.reserve(hash_len * 2);
          for (uint8_t b : digest) {
            result.push_back(kHex[(b >> 4) & 0xf]);
            result.push_back(kHex[b & 0xf]);
          }
        }
      }
      BCryptDestroyHash(hash);
    }
  }
  BCryptCloseAlgorithmProvider(alg, 0);
  return result;
}

std::string AesEncryptBase64(const std::string& data_base64,
                             const std::string& key_base64,
                             const std::string& iv_base64,
                             const std::string& transformation) {
  std::vector<uint8_t> data = Base64Decode(data_base64);
  std::vector<uint8_t> key = Base64Decode(key_base64);
  std::vector<uint8_t> iv = Base64Decode(iv_base64);
  if (data.empty() || key.empty()) return std::string();

  const bool cbc = transformation.find("/CBC/") != std::string::npos;
  BCRYPT_ALG_HANDLE alg = nullptr;
  if (!NT_SUCCESS(BCryptOpenAlgorithmProvider(&alg, BCRYPT_AES_ALGORITHM,
                                              nullptr, 0))) {
    return std::string();
  }
  const wchar_t* mode = cbc ? BCRYPT_CHAIN_MODE_CBC : BCRYPT_CHAIN_MODE_ECB;
  BCryptSetProperty(alg, BCRYPT_CHAINING_MODE, reinterpret_cast<PUCHAR>(
                                                   const_cast<wchar_t*>(mode)),
                    static_cast<ULONG>((wcslen(mode) + 1) * sizeof(wchar_t)), 0);

  ULONG object_len = 0;
  ULONG got = 0;
  std::string result;
  if (NT_SUCCESS(BCryptGetProperty(alg, BCRYPT_OBJECT_LENGTH,
                                   reinterpret_cast<PUCHAR>(&object_len),
                                   sizeof(object_len), &got, 0)) &&
      object_len > 0) {
    BCRYPT_KEY_HANDLE key_handle = nullptr;
    std::vector<uint8_t> key_object(object_len);
    std::vector<uint8_t> key_copy(key);
    if (NT_SUCCESS(BCryptGenerateSymmetricKey(
            alg, &key_handle, key_object.data(),
            static_cast<ULONG>(key_object.size()), key_copy.data(),
            static_cast<ULONG>(key_copy.size()), 0))) {
      std::vector<uint8_t> iv_buf(16, 0);
      if (cbc && !iv.empty()) {
        std::copy(iv.begin(), iv.begin() + std::min<size_t>(iv.size(), 16),
                  iv_buf.begin());
      }
      const ULONG out_len = static_cast<ULONG>(
          ((data.size() / 16) + 1) * 16);
      std::vector<uint8_t> cipher(out_len);
      ULONG done = 0;
      if (NT_SUCCESS(BCryptEncrypt(key_handle, data.data(),
                                   static_cast<ULONG>(data.size()), nullptr,
                                   cbc ? iv_buf.data() : nullptr,
                                   cbc ? 16UL : 0UL, cipher.data(), out_len,
                                   &done, BCRYPT_BLOCK_PADDING))) {
        cipher.resize(done);
        result = Base64Encode(cipher);
      }
      BCryptDestroyKey(key_handle);
    }
  }
  BCryptCloseAlgorithmProvider(alg, 0);
  return result;
}

namespace {

bool SkipDerTag(const std::vector<uint8_t>& der, size_t* pos, uint8_t tag,
                size_t* content_len) {
  if (*pos >= der.size() || der[*pos] != tag) return false;
  (*pos)++;
  if (*pos >= der.size()) return false;
  const uint8_t first = der[(*pos)++];
  size_t len = 0;
  if ((first & 0x80) == 0) {
    len = first;
  } else {
    const int count = first & 0x7f;
    if (count < 1 || count > 4 || *pos + count > der.size()) return false;
    for (int i = 0; i < count; i++) {
      len = (len << 8) | der[(*pos)++];
    }
  }
  if (*pos + len > der.size()) return false;
  *content_len = len;
  return true;
}

bool StripLeadingZero(const std::vector<uint8_t>& der, size_t pos, size_t len,
                      std::vector<uint8_t>* out) {
  if (len == 0 || pos + len > der.size()) return false;
  size_t start = pos;
  while (start < pos + len - 1 && der[start] == 0) start++;
  out->assign(der.begin() + static_cast<std::ptrdiff_t>(start),
              der.begin() + static_cast<std::ptrdiff_t>(pos + len));
  return !out->empty();
}

bool ParseSpkiPublicKey(const std::string& pem, std::vector<uint8_t>* modulus,
                        std::vector<uint8_t>* exponent) {
  // Strip PEM armor and whitespace.
  std::string b64;
  b64.reserve(pem.size());
  bool in_body = false;
  for (size_t i = 0; i < pem.size(); i++) {
    const char c = pem[i];
    if (c == '-') {
      // BEGIN line ends at the next newline; switch into body after it.
      const size_t nl = pem.find('\n', i);
      if (nl == std::string::npos) break;
      const std::string line = pem.substr(i, nl - i);
      if (line.find("BEGIN") != std::string::npos) {
        in_body = true;
        i = nl;
        continue;
      }
      if (line.find("END") != std::string::npos) break;
      i = nl;
      continue;
    }
    if (in_body && c != ' ' && c != '\n' && c != '\r' && c != '\t') {
      b64.push_back(c);
    }
  }
  if (b64.empty()) return false;
  std::vector<uint8_t> der = Base64Decode(b64);
  if (der.empty()) return false;

  size_t pos = 0;
  size_t len = 0;
  if (!SkipDerTag(der, &pos, 0x30, &len)) return false;  // SubjectPublicKeyInfo
  const size_t outer_end = pos + len;
  if (!SkipDerTag(der, &pos, 0x30, &len)) return false;  // AlgorithmIdentifier
  pos += len;  // skip it
  if (!SkipDerTag(der, &pos, 0x03, &len)) return false;  // BIT STRING
  if (len == 0 || der[pos] != 0) return false;
  pos++;  // unused bits
  const size_t bit_end = pos + len - 1;
  if (bit_end > outer_end) return false;
  if (!SkipDerTag(der, &pos, 0x30, &len)) return false;  // RSAPublicKey
  if (!SkipDerTag(der, &pos, 0x02, &len)) return false;  // modulus
  if (!StripLeadingZero(der, pos, len, modulus)) return false;
  pos += len;
  if (!SkipDerTag(der, &pos, 0x02, &len)) return false;  // exponent
  if (!StripLeadingZero(der, pos, len, exponent)) return false;
  return true;
}

}  // namespace

std::string RsaEncryptBase64(const std::string& data_base64,
                             const std::string& public_key_pem,
                             const std::string& padding) {
  std::vector<uint8_t> data = Base64Decode(data_base64);
  std::vector<uint8_t> modulus;
  std::vector<uint8_t> exponent;
  if (data.empty() || !ParseSpkiPublicKey(public_key_pem, &modulus, &exponent)) {
    return std::string();
  }

  BCRYPT_ALG_HANDLE alg = nullptr;
  if (!NT_SUCCESS(BCryptOpenAlgorithmProvider(&alg, BCRYPT_RSA_ALGORITHM,
                                              nullptr, 0))) {
    return std::string();
  }

  const size_t blob_len = sizeof(BCRYPT_RSAKEY_BLOB) + exponent.size() +
                          modulus.size();
  std::vector<uint8_t> blob(blob_len, 0);
  auto* key_blob = reinterpret_cast<BCRYPT_RSAKEY_BLOB*>(blob.data());
  key_blob->Magic = BCRYPT_RSAPUBLIC_MAGIC;
  key_blob->BitLength = static_cast<ULONG>(modulus.size() * 8);
  key_blob->cbPublicExp = static_cast<ULONG>(exponent.size());
  key_blob->cbModulus = static_cast<ULONG>(modulus.size());
  key_blob->cbPrime1 = 0;
  key_blob->cbPrime2 = 0;
  uint8_t* cursor = blob.data() + sizeof(BCRYPT_RSAKEY_BLOB);
  std::copy(exponent.begin(), exponent.end(), cursor);
  cursor += exponent.size();
  std::copy(modulus.begin(), modulus.end(), cursor);

  BCRYPT_KEY_HANDLE key_handle = nullptr;
  std::string result;
  if (NT_SUCCESS(BCryptImportKeyPair(alg, nullptr, BCRYPT_PUBLIC_KEY_BLOB,
                                     &key_handle, blob.data(),
                                     static_cast<ULONG>(blob.size()), 0))) {
    const ULONG out_len = static_cast<ULONG>(modulus.size());
    std::vector<uint8_t> cipher(out_len);
    ULONG done = 0;
    bool padded = false;
    void* pad_info = nullptr;
    DWORD flags = 0;
    BCRYPT_PKCS1_PADDING_INFO pkcs1 = {0};
    BCRYPT_OAEP_PADDING_INFO oaep = {0};
    const std::string upper = [&]() {
      std::string s = padding;
      std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) {
        return static_cast<char>(::toupper(c));
      });
      return s;
    }();
    if (upper.find("PKCS1") != std::string::npos) {
      pkcs1.pszAlgId = nullptr;
      pad_info = &pkcs1;
      flags = BCRYPT_PAD_PKCS1;
      padded = true;
    } else if (upper.find("OAEP") != std::string::npos) {
      oaep.pszAlgId = BCRYPT_SHA1_ALGORITHM;
      pad_info = &oaep;
      flags = BCRYPT_PAD_OAEP;
      padded = true;
    }
    NTSTATUS status = BCryptEncrypt(
        key_handle, data.data(), static_cast<ULONG>(data.size()), pad_info,
        nullptr, 0, cipher.data(), out_len, &done, flags);
    if (!padded && !NT_SUCCESS(status) && data.size() > modulus.size()) {
      // NoPadding requires input <= modulus size; JCE would have failed too.
      status = -1;
    }
    if (NT_SUCCESS(status)) {
      cipher.resize(done);
      result = Base64Encode(cipher);
    }
    BCryptDestroyKey(key_handle);
  }
  BCryptCloseAlgorithmProvider(alg, 0);
  return result;
}

}  // namespace ms_crypto
}  // namespace muyin
