#define _POSIX_C_SOURCE 200809L
#include "carracho_protocol.h"

#include <errno.h>
#include <limits.h>
#include <openssl/blowfish.h>
#include <openssl/evp.h>
#include <openssl/kdf.h>
#include <openssl/hmac.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

uint16_t cr_read_be16(const uint8_t *p) { return (uint16_t)(((uint16_t)p[0] << 8) | p[1]); }
uint32_t cr_read_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}
uint64_t cr_read_be64(const uint8_t *p) {
    uint64_t v = 0; for (int i = 0; i < 8; ++i) v = (v << 8) | p[i]; return v;
}
void cr_write_be16(uint8_t *p, uint16_t v) { p[0]=(uint8_t)(v>>8); p[1]=(uint8_t)v; }
void cr_write_be32(uint8_t *p, uint32_t v) {
    p[0]=(uint8_t)(v>>24); p[1]=(uint8_t)(v>>16); p[2]=(uint8_t)(v>>8); p[3]=(uint8_t)v;
}
void cr_write_be64(uint8_t *p, uint64_t v) {
    for (int i = 7; i >= 0; --i) { p[i]=(uint8_t)v; v >>= 8; }
}

int cr_hkdf_sha256(const uint8_t *input,size_t input_len,const uint8_t *salt,size_t salt_len,
                   const void *info,size_t info_len,uint8_t out[32]){
    if(!input||!input_len||!salt||!salt_len||!info||!out)return-1;
    EVP_PKEY_CTX *ctx=EVP_PKEY_CTX_new_id(EVP_PKEY_HKDF,NULL);if(!ctx)return-1;size_t out_len=32;int ok=-1;
    if(EVP_PKEY_derive_init(ctx)>0&&EVP_PKEY_CTX_hkdf_mode(ctx,EVP_PKEY_HKDEF_MODE_EXTRACT_AND_EXPAND)>0&&
       EVP_PKEY_CTX_set_hkdf_md(ctx,EVP_sha256())>0&&
       EVP_PKEY_CTX_set1_hkdf_salt(ctx,salt,(int)salt_len)>0&&
       EVP_PKEY_CTX_set1_hkdf_key(ctx,input,(int)input_len)>0&&
       EVP_PKEY_CTX_add1_hkdf_info(ctx,info,(int)info_len)>0&&EVP_PKEY_derive(ctx,out,&out_len)>0&&out_len==32)ok=0;
    EVP_PKEY_CTX_free(ctx);return ok;
}

int cr_x25519_generate(uint8_t private_key[32], uint8_t public_key[32]) {
  if (!private_key || !public_key)
    return -1;
  EVP_PKEY_CTX *ctx = EVP_PKEY_CTX_new_id(EVP_PKEY_X25519, NULL);
  if (!ctx)
    return -1;
  EVP_PKEY *key = NULL;
  int rc = -1;
  size_t n = 32, m = 32;
  if (EVP_PKEY_keygen_init(ctx) > 0 && EVP_PKEY_keygen(ctx, &key) > 0 &&
      EVP_PKEY_get_raw_private_key(key, private_key, &n) > 0 && n == 32 &&
      EVP_PKEY_get_raw_public_key(key, public_key, &m) > 0 && m == 32)
    rc = 0;
  EVP_PKEY_free(key);
  EVP_PKEY_CTX_free(ctx);
  return rc;
}

int cr_x25519_shared(const uint8_t private_key[32],
                     const uint8_t peer_public_key[32], uint8_t shared[32]) {
  if (!private_key || !peer_public_key || !shared)
    return -1;
  EVP_PKEY *priv =
      EVP_PKEY_new_raw_private_key(EVP_PKEY_X25519, NULL, private_key, 32);
  EVP_PKEY *peer =
      EVP_PKEY_new_raw_public_key(EVP_PKEY_X25519, NULL, peer_public_key, 32);
  if (!priv || !peer) {
    EVP_PKEY_free(priv);
    EVP_PKEY_free(peer);
    return -1;
  }
  EVP_PKEY_CTX *ctx = EVP_PKEY_CTX_new(priv, NULL);
  size_t n = 32;
  int rc = -1;
  if (ctx && EVP_PKEY_derive_init(ctx) > 0 &&
      EVP_PKEY_derive_set_peer(ctx, peer) > 0 &&
      EVP_PKEY_derive(ctx, shared, &n) > 0 && n == 32)
    rc = 0;
  EVP_PKEY_CTX_free(ctx);
  EVP_PKEY_free(peer);
  EVP_PKEY_free(priv);
  return rc;
}

int cr_transport_master(const uint8_t shared[32], const uint8_t *session_key,
                        size_t session_key_len,
                        const uint8_t session_salt[CR_MODERN_SESSION_SALT],
                        uint8_t out[32]) {
  if (!shared || !session_key || !session_key_len || !session_salt || !out)
    return -1;
  cr_buffer binding;
  cr_buffer_init(&binding);
  uint8_t digest[32];
  unsigned int digest_len = 0;
  int rc = -1;
  if (cr_buffer_append(&binding, "carracho/x25519/salt/v1",
                       strlen("carracho/x25519/salt/v1")) ||
      cr_buffer_append(&binding, session_key, session_key_len) ||
      cr_buffer_append(&binding, session_salt, CR_MODERN_SESSION_SALT))
    goto done;
  EVP_MD_CTX *md = EVP_MD_CTX_new();
  if (!md)
    goto done;
  if (EVP_DigestInit_ex(md, EVP_sha256(), NULL) != 1 ||
      EVP_DigestUpdate(md, binding.data, binding.len) != 1 ||
      EVP_DigestFinal_ex(md, digest, &digest_len) != 1 || digest_len != 32) {
    EVP_MD_CTX_free(md);
    goto done;
  }
  EVP_MD_CTX_free(md);
  if (cr_hkdf_sha256(shared, 32, digest, 32, "carracho/x25519/master/v1",
                     strlen("carracho/x25519/master/v1"), out) == 0)
    rc = 0;
done:
  cr_buffer_free(&binding);
  return rc;
}

int cr_handshake_authenticator(
    const uint8_t *session_key, size_t session_key_len,
    const uint8_t challenge[12], const uint8_t client_public_key[32],
    const uint8_t server_public_key[32],
    const uint8_t session_salt[CR_MODERN_SESSION_SALT], uint8_t out[32]) {
  if (!session_key || !session_key_len || !challenge || !client_public_key ||
      !server_public_key || !session_salt || !out || session_key_len > INT_MAX)
    return -1;
  cr_buffer transcript;
  cr_buffer_init(&transcript);
  unsigned int n = 0;
  int rc = -1;
  if (cr_buffer_append(&transcript, "carracho/x25519-auth/v1",
                       strlen("carracho/x25519-auth/v1")) ||
      cr_buffer_append(&transcript, challenge, 12) ||
      cr_buffer_append(&transcript, client_public_key, 32) ||
      cr_buffer_append(&transcript, server_public_key, 32) ||
      cr_buffer_append(&transcript, session_salt, CR_MODERN_SESSION_SALT))
    goto done;
  if (HMAC(EVP_sha256(), session_key, (int)session_key_len, transcript.data,
           transcript.len, out, &n) &&
      n == 32)
    rc = 0;
done:
  cr_buffer_free(&transcript);
  return rc;
}

static int derive_pair(const uint8_t *session_key,size_t session_key_len,const uint8_t *salt,size_t salt_len,
                       const char *left_info,const char *right_info,int server_role,uint8_t send_key[32],uint8_t receive_key[32]){
    uint8_t c2s[32],s2c[32];
    if(cr_hkdf_sha256(session_key,session_key_len,salt,salt_len,left_info,strlen(left_info),c2s)||
       cr_hkdf_sha256(session_key,session_key_len,salt,salt_len,right_info,strlen(right_info),s2c))return-1;
    if(server_role){memcpy(send_key,s2c,32);memcpy(receive_key,c2s,32);}else{memcpy(send_key,c2s,32);memcpy(receive_key,s2c,32);}return 0;
}

int cr_derive_control_keys(const uint8_t *session_key,size_t session_key_len,const uint8_t salt[CR_MODERN_SESSION_SALT],int server_role,
                           uint8_t send_key[32],uint8_t receive_key[32]){
    return derive_pair(session_key,session_key_len,salt,CR_MODERN_SESSION_SALT,
                       "carracho/aes-256-gcm/control/c2s/v1","carracho/aes-256-gcm/control/s2c/v1",
                       server_role,send_key,receive_key);
}

int cr_derive_transfer_keys(const uint8_t *session_key,size_t session_key_len,const uint8_t session_salt[CR_MODERN_SESSION_SALT],
                            const uint8_t transfer_nonce[CR_MODERN_TRANSFER_NONCE],uint16_t operation,int server_role,
                            uint8_t send_key[32],uint8_t receive_key[32]){
    uint8_t salt[CR_MODERN_SESSION_SALT+CR_MODERN_TRANSFER_NONCE];memcpy(salt,session_salt,CR_MODERN_SESSION_SALT);memcpy(salt+CR_MODERN_SESSION_SALT,transfer_nonce,CR_MODERN_TRANSFER_NONCE);
    char c2s[96],s2c[96];snprintf(c2s,sizeof(c2s),"carracho/aes-256-gcm/transfer/%04x/c2s/v1",operation);snprintf(s2c,sizeof(s2c),"carracho/aes-256-gcm/transfer/%04x/s2c/v1",operation);
    return derive_pair(session_key,session_key_len,salt,sizeof(salt),c2s,s2c,server_role,send_key,receive_key);
}

static void aead_nonce(uint64_t sequence,uint8_t nonce[12]){memset(nonce,0,4);cr_write_be64(nonce+4,sequence);}
static int aead_aad(const char*domain,uint32_t length,uint64_t sequence,cr_buffer*out){out->len=0;uint8_t h[12];cr_write_be32(h,length);cr_write_be64(h+4,sequence);return cr_buffer_append(out,domain,strlen(domain))||cr_buffer_append(out,h,sizeof(h))?-1:0;}

int cr_encode_aead(const uint8_t *plaintext, size_t plaintext_len,
                   const uint8_t key[32], uint64_t sequence, const char *domain,
                   cr_buffer *frame) {
  if ((plaintext_len && !plaintext) || !key || !domain || !frame ||
      plaintext_len > UINT32_MAX || plaintext_len > INT_MAX)
    return -1;
  uint8_t nonce[12], tag[16], header[12];
  aead_nonce(sequence, nonce);
  cr_write_be32(header, (uint32_t)plaintext_len);
  cr_write_be64(header + 4, sequence);
  cr_buffer aad;
  cr_buffer_init(&aad);
  if (aead_aad(domain, (uint32_t)plaintext_len, sequence, &aad)) {
    cr_buffer_free(&aad);
    return -1;
  }
  frame->len = 0;
  if (cr_buffer_reserve(frame, sizeof(header) + plaintext_len + sizeof(tag)) ||
      cr_buffer_append(frame, header, sizeof(header))) {
    cr_buffer_free(&aad);
    return -1;
  }
  EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
  if (!ctx) {
    cr_buffer_free(&aad);
    return -1;
  }
  int outl = 0, total = 0, ok = -1;
  uint8_t *cipher = malloc(plaintext_len ? plaintext_len : 1);
  if (!cipher)
    goto done;
  if (EVP_EncryptInit_ex(ctx, EVP_aes_256_gcm(), NULL, NULL, NULL) != 1 ||
      EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, sizeof(nonce), NULL) !=
          1 ||
      EVP_EncryptInit_ex(ctx, NULL, NULL, key, nonce) != 1)
    goto done;
  if (EVP_EncryptUpdate(ctx, NULL, &outl, aad.data, (int)aad.len) != 1)
    goto done;
  if (plaintext_len &&
      EVP_EncryptUpdate(ctx, cipher, &outl, plaintext, (int)plaintext_len) != 1)
    goto done;
  total = outl;
  if (EVP_EncryptFinal_ex(ctx, cipher + total, &outl) != 1)
    goto done;
  total += outl;
  if ((size_t)total != plaintext_len)
    goto done;
  if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, sizeof(tag), tag) != 1 ||
      cr_buffer_append(frame, cipher, plaintext_len) ||
      cr_buffer_append(frame, tag, sizeof(tag)))
    goto done;
  ok = 0;
done:
  free(cipher);
  EVP_CIPHER_CTX_free(ctx);
  cr_buffer_free(&aad);
  if (ok)
    frame->len = 0;
  return ok;
}

int cr_decode_aead(const uint8_t *frame, size_t frame_len,
                   const uint8_t key[32], uint64_t expected_sequence,
                   const char *domain, size_t maximum_plaintext,
                   cr_buffer *plaintext) {
  if (!frame || frame_len < CR_AEAD_HEADER_LENGTH + CR_AEAD_TAG_LENGTH ||
      !key || !domain || !plaintext)
    return -1;
  uint32_t n = cr_read_be32(frame);
  uint64_t seq = cr_read_be64(frame + 4);
  if (seq != expected_sequence || n > maximum_plaintext || n > INT_MAX ||
      frame_len != (size_t)CR_AEAD_HEADER_LENGTH + n + CR_AEAD_TAG_LENGTH)
    return -1;
  uint8_t nonce[12];
  aead_nonce(seq, nonce);
  cr_buffer aad;
  cr_buffer_init(&aad);
  if (aead_aad(domain, n, seq, &aad)) {
    cr_buffer_free(&aad);
    return -1;
  }
  const uint8_t *cipher = frame + CR_AEAD_HEADER_LENGTH, *tag = cipher + n;
  uint8_t *out = malloc(n ? n : 1);
  if (!out) {
    cr_buffer_free(&aad);
    return -1;
  }
  EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
  if (!ctx) {
    free(out);
    cr_buffer_free(&aad);
    return -1;
  }
  int outl = 0, total = 0, ok = -1;
  if (EVP_DecryptInit_ex(ctx, EVP_aes_256_gcm(), NULL, NULL, NULL) != 1 ||
      EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, sizeof(nonce), NULL) !=
          1 ||
      EVP_DecryptInit_ex(ctx, NULL, NULL, key, nonce) != 1)
    goto done;
  if (EVP_DecryptUpdate(ctx, NULL, &outl, aad.data, (int)aad.len) != 1)
    goto done;
  if (n && EVP_DecryptUpdate(ctx, out, &outl, cipher, (int)n) != 1)
    goto done;
  total = outl;
  if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, CR_AEAD_TAG_LENGTH,
                          (void *)tag) != 1 ||
      EVP_DecryptFinal_ex(ctx, out + total, &outl) != 1)
    goto done;
  total += outl;
  if (total != (int)n)
    goto done;
  plaintext->len = 0;
  if (cr_buffer_append(plaintext, out, n))
    goto done;
  ok = 0;
done:
  EVP_CIPHER_CTX_free(ctx);
  free(out);
  cr_buffer_free(&aad);
  if (ok)
    plaintext->len = 0;
  return ok;
}

void cr_buffer_init(cr_buffer *b) { memset(b, 0, sizeof(*b)); }
void cr_buffer_free(cr_buffer *b) { if (b) { free(b->data); memset(b,0,sizeof(*b)); } }
int cr_buffer_reserve(cr_buffer *b, size_t additional) {
    if (additional > SIZE_MAX - b->len) return -1;
    size_t required = b->len + additional;
    if (required <= b->cap) return 0;
    size_t cap = b->cap ? b->cap : 256;
    while (cap < required) {
        if (cap > SIZE_MAX / 2) { cap = required; break; }
        cap *= 2;
    }
    uint8_t *next = realloc(b->data, cap);
    if (!next) return -1;
    b->data = next; b->cap = cap; return 0;
}
int cr_buffer_append(cr_buffer *b, const void *data, size_t len) {
    if (cr_buffer_reserve(b, len) != 0) return -1;
    if (len) memcpy(b->data + b->len, data, len);
    b->len += len; return 0;
}
int cr_buffer_append_u8(cr_buffer *b, uint8_t v) { return cr_buffer_append(b,&v,1); }
int cr_buffer_append_u16(cr_buffer *b, uint16_t v) { uint8_t x[2];cr_write_be16(x,v);return cr_buffer_append(b,x,2); }
int cr_buffer_append_u32(cr_buffer *b, uint32_t v) { uint8_t x[4];cr_write_be32(x,v);return cr_buffer_append(b,x,4); }
int cr_buffer_append_u64(cr_buffer *b, uint64_t v) { uint8_t x[8];cr_write_be64(x,v);return cr_buffer_append(b,x,8); }
int cr_buffer_append_string16(cr_buffer *b, const void *data, size_t len) {
    if (len > UINT16_MAX) return -1;
    return cr_buffer_append_u16(b,(uint16_t)len) || cr_buffer_append(b,data,len) ? -1 : 0;
}

int cr_read_exact(int fd, void *buffer, size_t length) {
    uint8_t *p = buffer; size_t off=0;
    while (off<length) {
        ssize_t n=recv(fd,p+off,length-off,0);
        if(n<0){if(errno==EINTR)continue;return -1;} if(n==0)return -1; off+=(size_t)n;
    }
    return 0;
}
int cr_write_all(int fd, const void *buffer, size_t length) {
    const uint8_t *p=buffer; size_t off=0;
    while(off<length){
#ifdef MSG_NOSIGNAL
        ssize_t n=send(fd,p+off,length-off,MSG_NOSIGNAL);
#else
        ssize_t n=send(fd,p+off,length-off,0);
#endif
        if(n<0){if(errno==EINTR)continue;return -1;} if(n==0)return -1; off+=(size_t)n;
    }
    return 0;
}

int cr_derive_session_key(const uint8_t *password, size_t password_len,
                          const uint8_t challenge[12], uint8_t *out, size_t out_cap,
                          size_t *out_len) {
    if (!password || !challenge || !out || !out_len) return -1;
    size_t need = password_len < 13 ? 24 : password_len * 2;
    if (need > out_cap) return -1;
    size_t p=0;
    if (password_len < 13) {
        uint8_t filler=1;
        for(size_t i=0;i<12;++i){uint8_t v=i<password_len?password[i]:filler++;out[p++]=v^0x21;out[p++]=challenge[i];}
    } else {
        uint8_t filler=1;
        for(size_t i=0;i<password_len;++i){out[p++]=password[i]^0x21;out[p++]=i<12?challenge[i]:filler++;}
    }
    *out_len=p; return 0;
}

int cr_login_digest_hex(const uint8_t *password, size_t password_len,
                        const uint8_t challenge[12], uint8_t out_hex[32]) {
    uint8_t key[128], digest[EVP_MAX_MD_SIZE]; size_t key_len=0; unsigned digest_len=0;
    if(cr_derive_session_key(password,password_len,challenge,key,sizeof(key),&key_len)!=0)return -1;
    if(EVP_Digest(key,key_len,digest,&digest_len,EVP_md5(),NULL)!=1 || digest_len!=16)return -1;
    static const char hex[]="0123456789abcdef";
    for(unsigned i=0;i<16;++i){out_hex[i*2]=(uint8_t)hex[digest[i]>>4];out_hex[i*2+1]=(uint8_t)hex[digest[i]&15];}
    return 0;
}

static int bf_setup(BF_KEY *bf, const uint8_t *key, size_t key_len) {
    if(!key||key_len==0)return -1;
    if(key_len>72) key_len=72; /* Swift key schedule consumes at most 18*4 bytes. */
    BF_set_key(bf,(int)key_len,key); return 0;
}
static void bf_encrypt_words(BF_KEY *bf,uint32_t *left,uint32_t *right){BF_LONG x[2]={*left,*right};BF_encrypt(x,bf);*left=(uint32_t)x[0];*right=(uint32_t)x[1];}
static void bf_decrypt_words(BF_KEY *bf,uint32_t *left,uint32_t *right){BF_LONG x[2]={*left,*right};BF_decrypt(x,bf);*left=(uint32_t)x[0];*right=(uint32_t)x[1];}

int cr_encode_control(const uint8_t *plaintext, size_t plaintext_len,
                      const uint8_t *key, size_t key_len, cr_buffer *frame) {
    size_t padding=8-(plaintext_len%8); size_t enc_len=plaintext_len+padding;
    if(enc_len>UINT32_MAX)return -1;
    BF_KEY bf; if(bf_setup(&bf,key,key_len)!=0)return -1;
    frame->len=0; if(cr_buffer_reserve(frame,4+enc_len)!=0)return -1;
    if(cr_buffer_append_u32(frame,(uint32_t)enc_len)!=0)return -1;
    for(size_t off=0;off<enc_len;off+=8){
        uint8_t block[8]={0}; size_t take=off<plaintext_len?plaintext_len-off:0;if(take>8)take=8;
        if(take)memcpy(block,plaintext+off,take);
        uint32_t l=cr_read_be32(block),r=cr_read_be32(block+4);r^=CR_CONTROL_XOR_RIGHT;bf_encrypt_words(&bf,&l,&r);l^=CR_CONTROL_XOR_LEFT;
        cr_write_be32(block,l);cr_write_be32(block+4,r);if(cr_buffer_append(frame,block,8)!=0)return -1;
    }
    return 0;
}

int cr_decode_control(const uint8_t *ciphertext, size_t ciphertext_len,
                      const uint8_t *key, size_t key_len, cr_buffer *plaintext) {
    if(!ciphertext_len || ciphertext_len%8 || ciphertext_len>CR_MAX_CONTROL_CIPHERTEXT)return -1;
    BF_KEY bf;if(bf_setup(&bf,key,key_len)!=0)return -1; plaintext->len=0;if(cr_buffer_reserve(plaintext,ciphertext_len)!=0)return -1;
    for(size_t off=0;off<ciphertext_len;off+=8){
        uint32_t l=cr_read_be32(ciphertext+off),r=cr_read_be32(ciphertext+off+4);l^=CR_CONTROL_XOR_LEFT;bf_decrypt_words(&bf,&l,&r);r^=CR_CONTROL_XOR_RIGHT;
        uint8_t block[8];cr_write_be32(block,l);cr_write_be32(block+4,r);if(cr_buffer_append(plaintext,block,8)!=0)return -1;
    }
    return 0;
}

static int build_packet_internal(uint32_t command, uint32_t transaction_id, uint32_t reserved,
                                 const cr_tlv_out *fields, size_t field_count,
                                 int align_odd_values, cr_buffer *plaintext) {
    if (field_count > UINT16_MAX) return -1;
    size_t body = 0;
    for(size_t i=0;i<field_count;++i){
        size_t part=6u+fields[i].length+((align_odd_values&&fields[i].length&1u)?1u:0u);
        if(body>CR_MAX_BODY_LENGTH-part)return-1;
        body+=part;
    }
    plaintext->len=0;
    if(cr_buffer_append_u32(plaintext,command)||cr_buffer_append_u32(plaintext,transaction_id)||cr_buffer_append_u32(plaintext,(uint32_t)body)||
       cr_buffer_append_u32(plaintext,reserved)||cr_buffer_append_u16(plaintext,(uint16_t)field_count))return -1;
    for(size_t i=0;i<field_count;++i){
        if(cr_buffer_append_u32(plaintext,fields[i].type)||cr_buffer_append_u16(plaintext,fields[i].length)||
           cr_buffer_append(plaintext,fields[i].value,fields[i].length))return -1;
        if(align_odd_values&&(fields[i].length&1u)){uint8_t pad=0;if(cr_buffer_append(plaintext,&pad,1))return -1;}
    }
    return 0;
}

int cr_build_packet(uint32_t command, uint32_t transaction_id, uint32_t reserved,
                    const cr_tlv_out *fields, size_t field_count, cr_buffer *plaintext) {
    return build_packet_internal(command,transaction_id,reserved,fields,field_count,0,plaintext);
}

int cr_parse_packet(const uint8_t *plain,size_t len,cr_packet *packet,size_t *logical_length){
    if (len < CR_PACKET_HEADER_SIZE) return -1;
    uint32_t body = cr_read_be32(plain + 8);
    uint16_t fields = cr_read_be16(plain + 16);
    if(body>CR_MAX_BODY_LENGTH||fields>CR_MAX_TLVS||CR_PACKET_HEADER_SIZE+(size_t)body>len)return -1;
    packet->command=cr_read_be32(plain);packet->transaction_id=cr_read_be32(plain+4);packet->reserved=cr_read_be32(plain+12);packet->field_count=fields;
    size_t pos=CR_PACKET_HEADER_SIZE,end=pos+body;
    for(uint16_t i=0;i<fields;++i){if(pos+6>end)return -1;uint32_t type=cr_read_be32(plain+pos);uint16_t n=cr_read_be16(plain+pos+4);pos+=6;if(pos+n>end)return -1;packet->fields[i]=(cr_tlv){type,plain+pos,n};pos+=n;}
    if (pos != end) return -1;
    size_t trailing = len - end;
    /* Classic Carracho only uses the declared body length. Blowfish framing pads to
       the next 8-byte block, and the original client/server do not require those
       padding bytes to be zero. Keep the structural/body checks strict but ignore
       the contents of up to one encrypted padding block. */
    if (trailing > 8) return -1;
    if (logical_length) *logical_length = end;
    return 0;
}
const cr_tlv *cr_packet_field(const cr_packet *p,uint32_t type){for(uint16_t i=0;i<p->field_count;++i)if(p->fields[i].type==type)return&p->fields[i];return NULL;}

int cr_send_packet(int fd,const uint8_t*key,size_t key_len,uint32_t command,uint32_t tx,const cr_tlv_out*fields,size_t field_count){
    cr_buffer plain,frame;cr_buffer_init(&plain);cr_buffer_init(&frame);int ok=-1;
    /* Original Server 1.0b13 aligns odd-sized values inside command 0xc0 while the
       TLV length excludes the one-byte pad. Classic Client 1.0b10r4 relies on that
       layout, notably for tracker field 0x32 whose reply is exactly three bytes. */
    int align_odd_values=command==0x000000c0u;
    if(build_packet_internal(command,tx,0,fields,field_count,align_odd_values,&plain)==0&&
       cr_encode_control(plain.data,plain.len,key,key_len,&frame)==0&&cr_write_all(fd,frame.data,frame.len)==0)ok=0;
    cr_buffer_free(&plain);cr_buffer_free(&frame);return ok;
}
int cr_recv_packet(int fd,const uint8_t*key,size_t key_len,cr_packet*packet,cr_buffer*plaintext){
    uint8_t hdr[4];if(cr_read_exact(fd,hdr,4)!=0)return -1;uint32_t n=cr_read_be32(hdr);if(!n||n%8||n>CR_MAX_CONTROL_CIPHERTEXT)return -1;
    uint8_t *cipher=malloc(n);if(!cipher)return -1;int rc=-1;size_t logical=0;
    if(cr_read_exact(fd,cipher,n)==0&&cr_decode_control(cipher,n,key,key_len,plaintext)==0&&
       cr_parse_packet(plaintext->data,plaintext->len,packet,&logical)==0){
        size_t trailing=plaintext->len-logical;
        if(trailing<=8)rc=0;
    }
    free(cipher);return rc;
}

static int transfer_crypt(const uint8_t *in,size_t len,const uint8_t*key,size_t key_len,int decrypt,cr_buffer*out){
    if (len % 8) return -1;
    BF_KEY bf;
    if (bf_setup(&bf, key, key_len) != 0) return -1;
    out->len = 0;
    if (cr_buffer_reserve(out, len) != 0) return -1;
    for(size_t off=0;off<len;off+=8){uint32_t l=cr_read_be32(in+off),r=cr_read_be32(in+off+4);if(decrypt){r^=CR_TRANSFER_XOR_RIGHT;bf_decrypt_words(&bf,&l,&r);l^=CR_TRANSFER_XOR_LEFT;}else{l^=CR_TRANSFER_XOR_LEFT;bf_encrypt_words(&bf,&l,&r);r^=CR_TRANSFER_XOR_RIGHT;}uint8_t b[8];cr_write_be32(b,l);cr_write_be32(b+4,r);if(cr_buffer_append(out,b,8)!=0)return -1;}return 0;
}
int cr_transfer_stream_init(cr_transfer_stream *s, int fd, const uint8_t *key,
                            size_t key_len) {
  if (!s || !key || !key_len)
    return -1;
  memset(s, 0, sizeof(*s));
  s->fd = fd;
  s->mode = CR_TRANSFER_STREAM_BLOWFISH;
  if (key_len > sizeof(s->key))
    key_len = sizeof(s->key);
  memcpy(s->key, key, key_len);
  s->key_len = key_len;
  cr_buffer_init(&s->plaintext);
  return 0;
}
int cr_transfer_stream_init_plain(cr_transfer_stream*s,int fd){if(!s)return-1;memset(s,0,sizeof(*s));s->fd=fd;s->mode=CR_TRANSFER_STREAM_PLAIN;cr_buffer_init(&s->plaintext);return 0;}
int cr_transfer_stream_init_modern(
    cr_transfer_stream *s, int fd, const uint8_t *session_key,
    size_t session_key_len, const uint8_t session_salt[CR_MODERN_SESSION_SALT],
    const uint8_t transfer_nonce[CR_MODERN_TRANSFER_NONCE], uint16_t operation,
    int server_role) {
  if (!s || !session_key || !session_key_len || !session_salt ||
      !transfer_nonce)
    return -1;
  memset(s, 0, sizeof(*s));
  s->fd = fd;
  s->mode = CR_TRANSFER_STREAM_AEAD;
  cr_buffer_init(&s->plaintext);
  if (cr_derive_transfer_keys(session_key, session_key_len, session_salt,
                              transfer_nonce, operation, server_role,
                              s->send_key, s->receive_key)) {
    cr_buffer_free(&s->plaintext);
    return -1;
  }
  return 0;
}
void cr_transfer_stream_free(cr_transfer_stream*s){if(s)cr_buffer_free(&s->plaintext);}

static int transfer_send_blowfish(cr_transfer_stream*s,const void*payload,size_t payload_len){
    size_t padding=(8-(payload_len%8))%8,enc_len=payload_len+padding;if(enc_len>UINT32_MAX)return-1;uint8_t *padded=calloc(1,enc_len?enc_len:1);if(!padded)return-1;if(payload_len)memcpy(padded,payload,payload_len);cr_buffer enc,frame;cr_buffer_init(&enc);cr_buffer_init(&frame);int rc=-1;
    if(transfer_crypt(padded,enc_len,s->key,s->key_len,0,&enc)==0&&cr_buffer_append_u32(&frame,(uint32_t)enc_len)==0&&cr_buffer_append_u32(&frame,0)==0&&cr_buffer_append_u8(&frame,(uint8_t)padding)==0&&cr_buffer_append(&frame,enc.data,enc.len)==0&&cr_write_all(s->fd,frame.data,frame.len)==0)rc=0;
    free(padded);cr_buffer_free(&enc);cr_buffer_free(&frame);return rc;
}

int cr_transfer_send(cr_transfer_stream*s,const void*payload,size_t payload_len){
    if(!s||(payload_len&&!payload))return-1;
    if(s->mode==CR_TRANSFER_STREAM_PLAIN)return cr_write_all(s->fd,payload,payload_len);
    if(s->mode==CR_TRANSFER_STREAM_BLOWFISH)return transfer_send_blowfish(s,payload,payload_len);
    if(s->mode!=CR_TRANSFER_STREAM_AEAD)return-1;
    if(!payload_len)return 0;
    const uint8_t*p=payload;size_t offset=0;
    while(offset<payload_len){size_t n=payload_len-offset;if(n>CR_MAX_TRANSFER_FRAME)n=CR_MAX_TRANSFER_FRAME;cr_buffer frame;cr_buffer_init(&frame);int rc=cr_encode_aead(p+offset,n,s->send_key,s->send_sequence,"carracho/transfer/v1",&frame);if(!rc)rc=cr_write_all(s->fd,frame.data,frame.len);cr_buffer_free(&frame);if(rc)return-1;s->send_sequence++;offset+=n;}
    return 0;
}

static int transfer_read_blowfish_frame(cr_transfer_stream*s){
    uint8_t hdr[9];if(cr_read_exact(s->fd,hdr,9)!=0)return-1;uint32_t n=cr_read_be32(hdr);uint32_t reserved=cr_read_be32(hdr+4);uint8_t pad=hdr[8];if(reserved||pad>7||n%8||n>CR_MAX_TRANSFER_FRAME)return-1;uint8_t*cipher=malloc(n?n:1);if(!cipher)return-1;cr_buffer plain;cr_buffer_init(&plain);int rc=-1;
    if(cr_read_exact(s->fd,cipher,n)==0&&transfer_crypt(cipher,n,s->key,s->key_len,1,&plain)==0&&pad<=plain.len){size_t useful=plain.len-pad;if(cr_buffer_append(&s->plaintext,plain.data,useful)==0)rc=0;}free(cipher);cr_buffer_free(&plain);return rc;
}
static int transfer_read_aead_frame(cr_transfer_stream*s){
    uint8_t header[CR_AEAD_HEADER_LENGTH];if(cr_read_exact(s->fd,header,sizeof(header)))return-1;uint32_t n=cr_read_be32(header);uint64_t seq=cr_read_be64(header+4);if(n>CR_MAX_TRANSFER_FRAME||seq!=s->receive_sequence)return-1;
    size_t frame_len=sizeof(header)+(size_t)n+CR_AEAD_TAG_LENGTH;uint8_t*frame=malloc(frame_len);if(!frame)return-1;memcpy(frame,header,sizeof(header));cr_buffer plain;cr_buffer_init(&plain);int rc=-1;
    if(cr_read_exact(s->fd,frame+sizeof(header),(size_t)n+CR_AEAD_TAG_LENGTH)==0&&cr_decode_aead(frame,frame_len,s->receive_key,s->receive_sequence,"carracho/transfer/v1",CR_MAX_TRANSFER_FRAME,&plain)==0&&cr_buffer_append(&s->plaintext,plain.data,plain.len)==0){s->receive_sequence++;rc=0;}
    cr_buffer_free(&plain);free(frame);return rc;
}
int cr_transfer_read(cr_transfer_stream *s, void *out, size_t count) {
  if (!s || (count && !out))
    return -1;
  if (s->mode == CR_TRANSFER_STREAM_PLAIN)
    return cr_read_exact(s->fd, out, count);
  while (s->plaintext.len < count) {
    int rc = s->mode == CR_TRANSFER_STREAM_BLOWFISH
                 ? transfer_read_blowfish_frame(s)
             : s->mode == CR_TRANSFER_STREAM_AEAD ? transfer_read_aead_frame(s)
                                                  : -1;
    if (rc)
      return -1;
  }
  if (count)
    memcpy(out, s->plaintext.data, count);
  if (count < s->plaintext.len)
    memmove(s->plaintext.data, s->plaintext.data + count,
            s->plaintext.len - count);
  s->plaintext.len -= count;
  return 0;
}
int cr_transfer_read_u8(cr_transfer_stream*s,uint8_t*out){return cr_transfer_read(s,out,1);}
int cr_transfer_read_u16(cr_transfer_stream*s,uint16_t*out){uint8_t b[2];if(cr_transfer_read(s,b,2))return-1;*out=cr_read_be16(b);return 0;}
int cr_transfer_read_u32(cr_transfer_stream*s,uint32_t*out){uint8_t b[4];if(cr_transfer_read(s,b,4))return-1;*out=cr_read_be32(b);return 0;}
int cr_transfer_read_u64(cr_transfer_stream*s,uint64_t*out){uint8_t b[8];if(cr_transfer_read(s,b,8))return-1;*out=cr_read_be64(b);return 0;}
int cr_transfer_read_string16(cr_transfer_stream*s,cr_buffer*out,size_t maximum){uint16_t n;if(cr_transfer_read_u16(s,&n)||n>maximum)return-1;out->len=0;if(cr_buffer_reserve(out,n))return-1;out->len=n;return n?cr_transfer_read(s,out->data,n):0;}
