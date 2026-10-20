/// The sign-in form's own client-side password encryption.
///
/// ## Where this comes from
///
/// Not guessed and not reconstructed from a screenshot: the algorithm below is a
/// transcription of the live page's `encrypt.js`, fetched from
/// `https://cas.whu.edu.cn/authserver/whuThemeNew1/static/common/encrypt.js`
/// (13 772 B). The whole of the relevant part is:
///
/// ```js
/// var $aes_chars = "ABCDEFGHJKMNPQRSTWXYZabcdefhijkmnprstwxyz2345678";
///
/// function randomString(n) {
///   var f = "";
///   for (i = 0; i < n; i++) f += $aes_chars.charAt(Math.floor(Math.random() * aes_chars_len));
///   return f;
/// }
///
/// function getAesString(n, f, c) {            // plaintext, key, iv
///   f = f.replace(/(^\s+)|(\s+$)/g, "");      // trim the key only
///   f = CryptoJS.enc.Utf8.parse(f);
///   c = CryptoJS.enc.Utf8.parse(c);
///   return CryptoJS.AES.encrypt(n, f, { iv: c, mode: CryptoJS.mode.CBC,
///                                       padding: CryptoJS.pad.Pkcs7 }).toString();
/// }
///
/// function encryptAES(n, f) { return f ? getAesString(randomString(64) + n, f, randomString(16)) : n; }
/// function encryptPassword(n, f) { try { return encryptAES(n, f); } catch (c) {} return n; }
/// ```
///
/// and it is called from `login.js` as
///
/// ```js
/// $("#saltPassword").val(encryptPassword($("#password").val(), $("#pwdEncryptSalt").val()));
/// $(LOGIN_PASSWORD_ID).attr("disabled", "disabled");   // the visible field is dropped
/// ```
///
/// Three consequences worth stating plainly, because each one is a silent
/// failure if missed:
///
///   * **No RSA anywhere.** An earlier reading assumed the usual Apereo scheme
///     (RSA-wrapped AES key). This deployment does not use one, so no key
///     material has to be fetched or embedded.
///   * **The key is trimmed, the plaintext is not.** `f.replace` runs on the
///     salt, and the 64-random-character prefix is prepended *after* that.
///   * **An empty salt means the password goes out in the clear.** That is the
///     vendor's own fallback, and it is mirrored here rather than "fixed",
///     because sending something else when the server expects plaintext would
///     simply fail to sign in. [casEncryptPassword] reports it so a caller can
///     decide whether to proceed.
///
/// One place deliberately does **not** mirror the reference, and it is recorded
/// rather than glossed over. The vendor tests the *raw* salt for truthiness and
/// only then trims it for the key, so a salt of `"   "` reaches AES with a
/// zero-length key. CryptoJS does not validate key length and emits ciphertext
/// anyway; nothing on the server could decrypt it. This file raises
/// [ArgumentError] instead. The difference is unreachable in practice — the page
/// always emits a 16-character salt — and a loud failure is preferable to a
/// request that looks well-formed and cannot work. `test/fixtures/
/// cas_password_vectors.json` carries both the comparable vectors and the
/// reference's output for that case, so the divergence stays visible.
///
/// ## How it is verified
///
/// Not by reading it carefully. `bin/verify_cas_crypto.dart` re-runs the
/// vendor's own `encrypt.js` under Node with a pinned key, IV and random
/// sequence, and compares its ciphertext byte-for-byte with this file's output
/// for the same inputs. A transcription error in the alphabet, the prefix
/// length, the trim, the mode, the padding or the encoding shows up as a
/// mismatch rather than as a login that mysteriously fails.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// The vendor's random-character alphabet, verbatim.
///
/// Deliberately *not* the usual `A-Za-z0-9`: `I`, `l`, `O`, `0`, `1` and `9` are
/// absent. The key is a UTF-8 string drawn from this set, so it stays printable
/// ASCII either way — but using the right alphabet keeps the generated material
/// the same *shape* as the reference implementation, which is what makes the
/// differential test meaningful.
const String casAesAlphabet =
    'ABCDEFGHJKMNPQRSTWXYZabcdefhijkmnprstwxyz2345678';

/// How many random characters the vendor prepends to the password.
const int casPasswordPrefixLength = 64;

/// How many random characters form the AES IV.
const int casIvLength = 16;

/// Builds one of the form's random strings.
///
/// [random] is injectable so the differential test can pin it; production passes
/// nothing and gets a fresh [Random].
String casRandomString(int length, [Random? random]) {
  final rng = random ?? Random.secure();
  final out = StringBuffer();
  for (var i = 0; i < length; i++) {
    out.write(casAesAlphabet[rng.nextInt(casAesAlphabet.length)]);
  }
  return out.toString();
}

/// The outcome of encrypting a password for the sign-in form.
class CasEncryptedPassword {
  const CasEncryptedPassword({required this.value, required this.wasEncrypted});

  /// What to put in the `password` form field.
  final String value;

  /// Whether [value] is ciphertext. False means the server sent a blank salt and
  /// [value] is the password itself — the vendor's own fallback. Callers should
  /// surface this rather than send it quietly over a channel they believed was
  /// protected.
  final bool wasEncrypted;
}

/// Encrypts [password] exactly as the sign-in form does.
///
/// [salt] is the page's `#pwdEncryptSalt` value. [random] is injectable for
/// testing; production passes nothing.
CasEncryptedPassword casEncryptPassword({
  required String password,
  required String salt,
  Random? random,
}) {
  // `f ? ... : n` — JS truthiness, applied to the *raw* salt. `""` short-circuits
  // to plaintext; `"   "` does not, and reaches the cipher below with a key that
  // trims to nothing, where it raises. See the library doc for why that one case
  // is not reproduced.
  if (salt.isEmpty) {
    return CasEncryptedPassword(value: password, wasEncrypted: false);
  }

  final rng = random ?? Random.secure();
  final key = utf8.encode(salt.trim());

  // Draw order is not interchangeable. The reference evaluates
  // `getAesString(randomString(64) + n, f, randomString(16))`, and JavaScript
  // resolves arguments left to right: the 64-character prefix consumes the
  // sequence *first*, the IV second. Reversing them yields ciphertext of exactly
  // the right length with entirely different contents — which is how this was
  // found, by the differential test and not by reading.
  final plaintext =
      utf8.encode(casRandomString(casPasswordPrefixLength, rng) + password);
  final iv = utf8.encode(casRandomString(casIvLength, rng));

  return CasEncryptedPassword(
    value: base64.encode(_aesCbcPkcs7(key: key, iv: iv, plaintext: plaintext)),
    wasEncrypted: true,
  );
}

/// AES-CBC with PKCS#7 padding — the mode and padding the vendor's call selects.
Uint8List _aesCbcPkcs7({
  required List<int> key,
  required List<int> iv,
  required List<int> plaintext,
}) {
  if (key.length != 16 && key.length != 24 && key.length != 32) {
    throw ArgumentError.value(
      key.length,
      'key',
      'AES needs a 16, 24 or 32 byte key; the page sent a salt of this length',
    );
  }
  if (iv.length != 16) {
    throw ArgumentError.value(iv.length, 'iv', 'AES needs a 16 byte IV');
  }

  final cipher = PaddedBlockCipherImpl(
    PKCS7Padding(),
    CBCBlockCipher(AESEngine()),
  )..init(
      true,
      PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
        ParametersWithIV<KeyParameter>(
            KeyParameter(Uint8List.fromList(key)), Uint8List.fromList(iv)),
        null,
      ),
    );

  return cipher.process(Uint8List.fromList(plaintext));
}
