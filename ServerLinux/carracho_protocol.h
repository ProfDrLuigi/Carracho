#ifndef CARRACHO_PROTOCOL_H
#define CARRACHO_PROTOCOL_H

#include <stddef.h>
#include <stdint.h>

#define CR_PACKET_HEADER_SIZE 18u
#define CR_MAX_BODY_LENGTH 0x20000u
#define CR_MAX_CONTROL_CIPHERTEXT (CR_PACKET_HEADER_SIZE + CR_MAX_BODY_LENGTH + 8u)
#define CR_MAX_TLVS 1024u
#define CR_CONTROL_XOR_LEFT  0x10576419u
#define CR_CONTROL_XOR_RIGHT 0x58022919u
#define CR_TRANSFER_XOR_LEFT  0x10576419u
#define CR_TRANSFER_XOR_RIGHT 0x58022919u
#define CR_MAX_TRANSFER_FRAME (4u * 1024u * 1024u)
#define CR_MODERN_SESSION_SALT 32u
#define CR_MODERN_TRANSFER_NONCE 16u
#define CR_AEAD_TAG_LENGTH 16u
#define CR_AEAD_HEADER_LENGTH 12u

typedef struct cr_buffer {
    uint8_t *data;
    size_t len;
    size_t cap;
} cr_buffer;

typedef struct cr_tlv {
    uint32_t type;
    const uint8_t *value;
    uint16_t length;
} cr_tlv;

typedef struct cr_packet {
    uint32_t command;
    uint32_t transaction_id;
    uint32_t reserved;
    uint16_t field_count;
    cr_tlv fields[CR_MAX_TLVS];
} cr_packet;

typedef struct cr_tlv_out {
    uint32_t type;
    const void *value;
    uint16_t length;
} cr_tlv_out;

typedef enum cr_transfer_stream_mode {
    CR_TRANSFER_STREAM_PLAIN = 0,
    CR_TRANSFER_STREAM_BLOWFISH = 1,
    CR_TRANSFER_STREAM_AEAD = 2
} cr_transfer_stream_mode;

typedef struct cr_transfer_stream {
    int fd;
    cr_transfer_stream_mode mode;
    uint8_t key[72];
    size_t key_len;
    uint8_t send_key[32];
    uint8_t receive_key[32];
    uint64_t send_sequence;
    uint64_t receive_sequence;
    cr_buffer plaintext;
} cr_transfer_stream;

uint16_t cr_read_be16(const uint8_t *p);
uint32_t cr_read_be32(const uint8_t *p);
uint64_t cr_read_be64(const uint8_t *p);
void cr_write_be16(uint8_t *p, uint16_t v);
void cr_write_be32(uint8_t *p, uint32_t v);
void cr_write_be64(uint8_t *p, uint64_t v);

void cr_buffer_init(cr_buffer *b);
void cr_buffer_free(cr_buffer *b);
int cr_buffer_reserve(cr_buffer *b, size_t additional);
int cr_buffer_append(cr_buffer *b, const void *data, size_t len);
int cr_buffer_append_u8(cr_buffer *b, uint8_t v);
int cr_buffer_append_u16(cr_buffer *b, uint16_t v);
int cr_buffer_append_u32(cr_buffer *b, uint32_t v);
int cr_buffer_append_u64(cr_buffer *b, uint64_t v);
int cr_buffer_append_string16(cr_buffer *b, const void *data, size_t len);

int cr_read_exact(int fd, void *buffer, size_t length);
int cr_write_all(int fd, const void *buffer, size_t length);


int cr_hkdf_sha256(const uint8_t *input, size_t input_len, const uint8_t *salt, size_t salt_len,
                   const void *info, size_t info_len, uint8_t out[32]);
int cr_x25519_generate(uint8_t private_key[32], uint8_t public_key[32]);
int cr_x25519_shared(const uint8_t private_key[32], const uint8_t peer_public_key[32], uint8_t shared[32]);
int cr_transport_master(const uint8_t shared[32], const uint8_t *session_key, size_t session_key_len,
                        const uint8_t session_salt[CR_MODERN_SESSION_SALT], uint8_t out[32]);
int cr_handshake_authenticator(const uint8_t *session_key, size_t session_key_len,
                               const uint8_t challenge[12], const uint8_t client_public_key[32],
                               const uint8_t server_public_key[32],
                               const uint8_t session_salt[CR_MODERN_SESSION_SALT], uint8_t out[32]);
int cr_derive_control_keys(const uint8_t *session_key, size_t session_key_len,
                           const uint8_t salt[CR_MODERN_SESSION_SALT], int server_role,
                           uint8_t send_key[32], uint8_t receive_key[32]);
int cr_derive_transfer_keys(const uint8_t *session_key, size_t session_key_len,
                            const uint8_t session_salt[CR_MODERN_SESSION_SALT],
                            const uint8_t transfer_nonce[CR_MODERN_TRANSFER_NONCE], uint16_t operation,
                            int server_role, uint8_t send_key[32], uint8_t receive_key[32]);
int cr_encode_aead(const uint8_t *plaintext, size_t plaintext_len, const uint8_t key[32],
                   uint64_t sequence, const char *domain, cr_buffer *frame);
int cr_decode_aead(const uint8_t *frame, size_t frame_len, const uint8_t key[32],
                   uint64_t expected_sequence, const char *domain, size_t maximum_plaintext,
                   cr_buffer *plaintext);

int cr_derive_session_key(const uint8_t *password, size_t password_len,
                          const uint8_t challenge[12], uint8_t *out, size_t out_cap,
                          size_t *out_len);
int cr_login_digest_hex(const uint8_t *password, size_t password_len,
                        const uint8_t challenge[12], uint8_t out_hex[32]);

int cr_encode_control(const uint8_t *plaintext, size_t plaintext_len,
                      const uint8_t *key, size_t key_len, cr_buffer *frame);
int cr_decode_control(const uint8_t *ciphertext, size_t ciphertext_len,
                      const uint8_t *key, size_t key_len, cr_buffer *plaintext);
int cr_build_packet(uint32_t command, uint32_t transaction_id, uint32_t reserved,
                    const cr_tlv_out *fields, size_t field_count, cr_buffer *plaintext);
int cr_parse_packet(const uint8_t *plaintext, size_t plaintext_len, cr_packet *packet,
                    size_t *logical_length);
const cr_tlv *cr_packet_field(const cr_packet *packet, uint32_t type);
int cr_send_packet(int fd, const uint8_t *key, size_t key_len,
                   uint32_t command, uint32_t transaction_id,
                   const cr_tlv_out *fields, size_t field_count);
int cr_recv_packet(int fd, const uint8_t *key, size_t key_len,
                   cr_packet *packet, cr_buffer *plaintext);

int cr_transfer_stream_init(cr_transfer_stream *s, int fd, const uint8_t *key, size_t key_len);
int cr_transfer_stream_init_plain(cr_transfer_stream *s, int fd);
int cr_transfer_stream_init_modern(cr_transfer_stream *s, int fd,
                                   const uint8_t *session_key, size_t session_key_len,
                                   const uint8_t session_salt[CR_MODERN_SESSION_SALT],
                                   const uint8_t transfer_nonce[CR_MODERN_TRANSFER_NONCE],
                                   uint16_t operation, int server_role);
void cr_transfer_stream_free(cr_transfer_stream *s);
int cr_transfer_send(cr_transfer_stream *s, const void *payload, size_t payload_len);
int cr_transfer_read(cr_transfer_stream *s, void *out, size_t count);
int cr_transfer_read_u8(cr_transfer_stream *s, uint8_t *out);
int cr_transfer_read_u16(cr_transfer_stream *s, uint16_t *out);
int cr_transfer_read_u32(cr_transfer_stream *s, uint32_t *out);
int cr_transfer_read_u64(cr_transfer_stream *s, uint64_t *out);
int cr_transfer_read_string16(cr_transfer_stream *s, cr_buffer *out, size_t maximum);

#endif
