#define _POSIX_C_SOURCE 200809L
#include "media_store.h"
#include "carracho_protocol.h"

#include <errno.h>
#include <fcntl.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

static int exec_sql(sqlite3 *db, const char *sql) {
  char *err = NULL;
  int rc = sqlite3_exec(db, sql, NULL, NULL, &err);
  if (rc != SQLITE_OK) {
    if (err)
      sqlite3_free(err);
    return -1;
  }
  return 0;
}
static int ensure_dir(const char *path) {
  if (mkdir(path, 0755) == 0 || errno == EEXIST)
    return 0;
  return -1;
}
static int ensure_tree(const char *path) {
  char tmp[PATH_MAX];
  size_t n = strlen(path);
  if (!n || n >= sizeof(tmp))
    return -1;
  memcpy(tmp, path, n + 1);
  for (char *p = tmp + 1; *p; p++)
    if (*p == '/') {
      *p = '\0';
      if (ensure_dir(tmp)) {
        *p = '/';
        return -1;
      }
      *p = '/';
    }
  return ensure_dir(tmp);
}
static int join_path(char *out, size_t cap, const char *a, const char *b) {
  int n = snprintf(out, cap, "%s/%s", a, b);
  return n < 0 || (size_t)n >= cap ? -1 : 0;
}
static int make_uuid(char out[37]) {
  uint8_t b[16];
  if (RAND_bytes(b, sizeof(b)) != 1)
    return -1;
  b[6] = (uint8_t)((b[6] & 0x0f) | 0x40);
  b[8] = (uint8_t)((b[8] & 0x3f) | 0x80);
  int n = snprintf(
      out, 37,
      "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
      b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11],
      b[12], b[13], b[14], b[15]);
  return n == 36 ? 0 : -1;
}
static int sha256_hex(const uint8_t *data, size_t len, char out[65]) {
  EVP_MD_CTX *ctx = EVP_MD_CTX_new();
  if (!ctx)
    return -1;
  unsigned char digest[EVP_MAX_MD_SIZE];
  unsigned n = 0;
  int rc = EVP_DigestInit_ex(ctx, EVP_sha256(), NULL) == 1 &&
                   EVP_DigestUpdate(ctx, data, len) == 1 &&
                   EVP_DigestFinal_ex(ctx, digest, &n) == 1 && n == 32
               ? 0
               : -1;
  EVP_MD_CTX_free(ctx);
  if (rc)
    return -1;
  for (unsigned i = 0; i < n; i++)
    snprintf(out + i * 2, 3, "%02x", digest[i]);
  return 0;
}
static int png_info(const uint8_t *d, size_t n, uint32_t *w, uint32_t *h) {
  static const uint8_t sig[8] = {0x89, 0x50, 0x4e, 0x47,
                                 0x0d, 0x0a, 0x1a, 0x0a};
  if (n < 24 || memcmp(d, sig, 8) || memcmp(d + 12, "IHDR", 4))
    return -1;
  *w = cr_read_be32(d + 16);
  *h = cr_read_be32(d + 20);
  return *w && *h ? 0 : -1;
}
static int jpeg_info(const uint8_t *d, size_t n, uint32_t *w, uint32_t *h) {
  if (n < 4 || d[0] != 0xff || d[1] != 0xd8)
    return -1;
  size_t p = 2;
  while (p + 4 <= n) {
    while (p < n && d[p] == 0xff)
      p++;
    if (p >= n)
      return -1;
    uint8_t m = d[p++];
    if (m == 0xd9 || m == 0xda)
      return -1;
    if (m == 0x01 || (m >= 0xd0 && m <= 0xd7))
      continue;
    if (p + 2 > n)
      return -1;
    uint16_t l = (uint16_t)(((uint16_t)d[p] << 8) | d[p + 1]);
    if (l < 2 || p + l > n)
      return -1;
    int sof = (m >= 0xc0 && m <= 0xc3) || (m >= 0xc5 && m <= 0xc7) ||
              (m >= 0xc9 && m <= 0xcb) || (m >= 0xcd && m <= 0xcf);
    if (sof) {
      if (l < 7)
        return -1;
      *h = (uint32_t)(((uint16_t)d[p + 3] << 8) | d[p + 4]);
      *w = (uint32_t)(((uint16_t)d[p + 5] << 8) | d[p + 6]);
      return *w && *h ? 0 : -1;
    }
    p += l;
  }
  return -1;
}
static int image_info(const uint8_t *d, size_t n, const char **mime,
                      uint32_t *w, uint32_t *h) {
  if (!png_info(d, n, w, h))
    *mime = "image/png";
  else if (!jpeg_info(d, n, w, h))
    *mime = "image/jpeg";
  else
    return -1;
  return *w <= CR_MEDIA_MAX_DIMENSION && *h <= CR_MEDIA_MAX_DIMENSION ? 0 : -1;
}
static void clean_filename(const char *raw, const char *mime, char out[1025]) {
  const char *leaf =
      raw && *raw ? raw
                  : (strcmp(mime, "image/png") ? "image.jpg" : "image.png");
  const char *s = strrchr(leaf, '/');
  if (s)
    leaf = s + 1;
  s = strrchr(leaf, '\\');
  if (s)
    leaf = s + 1;
  if (!*leaf)
    leaf = strcmp(mime, "image/png") ? "image.jpg" : "image.png";
  snprintf(out, 1025, "%.1024s", leaf);
}
static int write_atomic(const char *path, const uint8_t *data, size_t len) {
  char tmp[PATH_MAX];
  if (snprintf(tmp, sizeof(tmp), "%s.tmp.%ld", path, (long)getpid()) >=
      (int)sizeof(tmp))
    return -1;
  int fd = open(tmp, O_CREAT | O_EXCL | O_WRONLY, 0644);
  if (fd < 0)
    return -1;
  size_t off = 0;
  int rc = 0;
  while (off < len) {
    ssize_t n = write(fd, data + off, len - off);
    if (n < 0) {
      if (errno == EINTR)
        continue;
      rc = -1;
      break;
    }
    off += (size_t)n;
  }
  if (!rc && fsync(fd))
    rc = -1;
  if (close(fd) && !rc)
    rc = -1;
  if (!rc && rename(tmp, path))
    rc = -1;
  if (rc)
    unlink(tmp);
  return rc;
}
static int delete_orphans_locked(cr_media_store *s, time_t now) {
  sqlite3_stmt *mark = NULL;
  if (sqlite3_prepare_v2(s->db,
                         "UPDATE media_objects SET expires_at=? WHERE "
                         "expires_at IS NULL AND NOT EXISTS(SELECT 1 FROM "
                         "media_refs r WHERE r.media_id=media_objects.id)",
                         -1, &mark, NULL) != SQLITE_OK)
    return -1;
  sqlite3_bind_int64(mark, 1, (sqlite3_int64)now);
  if (sqlite3_step(mark) != SQLITE_DONE) {
    sqlite3_finalize(mark);
    return -1;
  }
  sqlite3_finalize(mark);
  sqlite3_stmt *st = NULL;
  if (sqlite3_prepare_v2(
          s->db,
          "SELECT id,relative_path FROM media_objects WHERE expires_at IS NOT "
          "NULL AND expires_at<=? AND NOT EXISTS(SELECT 1 FROM media_refs r "
          "WHERE r.media_id=media_objects.id)",
          -1, &st, NULL) != SQLITE_OK)
    return -1;
  sqlite3_bind_int64(st, 1, (sqlite3_int64)now);
  char **ids = NULL, **paths = NULL;
  size_t count = 0, cap = 0;
  int step;
  while ((step = sqlite3_step(st)) == SQLITE_ROW) {
    if (count == cap) {
      size_t nc = cap ? cap * 2 : 16;
      char **ni = realloc(ids, nc * sizeof(*ni));
      char **np = realloc(paths, nc * sizeof(*np));
      if (!ni || !np) {
        free(ni);
        free(np);
        step = SQLITE_NOMEM;
        break;
      }
      ids = ni;
      paths = np;
      cap = nc;
    }
    const char *i = (const char *)sqlite3_column_text(st, 0),
               *p = (const char *)sqlite3_column_text(st, 1);
    ids[count] = strdup(i ? i : "");
    paths[count] = strdup(p ? p : "");
    if (!ids[count] || !paths[count]) {
      step = SQLITE_NOMEM;
      break;
    }
    count++;
  }
  sqlite3_finalize(st);
  if (step != SQLITE_DONE) {
    for (size_t i = 0; i < count; i++) {
      free(ids[i]);
      free(paths[i]);
    }
    free(ids);
    free(paths);
    return -1;
  }
  for (size_t i = 0; i < count; i++) {
    sqlite3_stmt *d = NULL;
    if (sqlite3_prepare_v2(s->db, "DELETE FROM media_objects WHERE id=?", -1,
                           &d, NULL) != SQLITE_OK) {
      for (; i < count; i++) {
        free(ids[i]);
        free(paths[i]);
      }
      free(ids);
      free(paths);
      return -1;
    }
    sqlite3_bind_text(d, 1, ids[i], -1, SQLITE_TRANSIENT);
    int ok = sqlite3_step(d) == SQLITE_DONE;
    sqlite3_finalize(d);
    if (ok) {
      char full[PATH_MAX];
      if (!join_path(full, sizeof(full), s->objects_root, paths[i]))
        unlink(full);
    }
    free(ids[i]);
    free(paths[i]);
  }
  free(ids);
  free(paths);
  return 0;
}
int cr_media_store_init(cr_media_store *s, const char *db_path,
                        const char *objects_root) {
  if (!s || !db_path || !objects_root)
    return -1;
  memset(s, 0, sizeof(*s));
  if (strlen(objects_root) >= sizeof(s->objects_root))
    return -1;
  strcpy(s->objects_root, objects_root);
  if (ensure_tree(objects_root) || pthread_mutex_init(&s->mutex, NULL))
    return -1;
  if (sqlite3_open_v2(db_path, &s->db,
                      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE |
                          SQLITE_OPEN_FULLMUTEX,
                      NULL) != SQLITE_OK) {
    if (s->db)
      sqlite3_close(s->db);
    s->db = NULL;
    pthread_mutex_destroy(&s->mutex);
    return -1;
  }
  sqlite3_busy_timeout(s->db, 5000);
  if (exec_sql(
          s->db,
          "PRAGMA journal_mode=WAL;PRAGMA synchronous=NORMAL;PRAGMA "
          "foreign_keys=ON;CREATE TABLE IF NOT EXISTS media_objects(id TEXT "
          "PRIMARY KEY,owner_account_id TEXT NOT NULL,mime_type TEXT NOT "
          "NULL,filename TEXT NOT NULL,byte_count INTEGER NOT NULL,width "
          "INTEGER NOT NULL,height INTEGER NOT NULL,sha256 TEXT NOT "
          "NULL,created_at INTEGER NOT NULL,expires_at INTEGER,relative_path "
          "TEXT NOT NULL UNIQUE);CREATE TABLE IF NOT EXISTS "
          "media_refs(media_id TEXT NOT NULL,kind INTEGER NOT NULL,scope TEXT "
          "NOT NULL,message_id TEXT NOT NULL,created_at INTEGER NOT "
          "NULL,expires_at INTEGER,PRIMARY "
          "KEY(media_id,kind,scope,message_id),FOREIGN KEY(media_id) "
          "REFERENCES media_objects(id) ON DELETE CASCADE);CREATE INDEX IF NOT "
          "EXISTS media_refs_scope_idx ON media_refs(kind,scope);")) {
    cr_media_store_destroy(s);
    return -1;
  }
  return cr_media_store_cleanup(s, time(NULL));
}
void cr_media_store_destroy(cr_media_store *s) {
  if (!s)
    return;
  pthread_mutex_lock(&s->mutex);
  if (s->db)
    sqlite3_close(s->db);
  s->db = NULL;
  pthread_mutex_unlock(&s->mutex);
  pthread_mutex_destroy(&s->mutex);
}
int cr_media_store_pending(cr_media_store *s, const char *owner,
                           const char *filename, const uint8_t *data,
                           size_t len, char out_id[37]) {
  if (!s || !owner || !*owner || !data || !len || len > CR_MEDIA_MAX_BYTES ||
      !out_id)
    return -1;
  const char *mime = NULL;
  uint32_t w = 0, h = 0;
  if (image_info(data, len, &mime, &w, &h))
    return -1;
  char id[37], sha[65], clean[1025], dir[PATH_MAX], relative[128],
      path[PATH_MAX];
  if (make_uuid(id) || sha256_hex(data, len, sha))
    return -1;
  clean_filename(filename, mime, clean);
  if (snprintf(relative, sizeof(relative), "%.2s/%s.bin", id, id) >=
          (int)sizeof(relative) ||
      snprintf(dir, sizeof(dir), "%s/%.2s", s->objects_root, id) >=
          (int)sizeof(dir) ||
      ensure_dir(dir) ||
      join_path(path, sizeof(path), s->objects_root, relative) ||
      write_atomic(path, data, len))
    return -1;
  pthread_mutex_lock(&s->mutex);
  sqlite3_stmt *st = NULL;
  int rc = -1;
  if (sqlite3_prepare_v2(s->db,
                         "INSERT INTO "
                         "media_objects(id,owner_account_id,mime_type,filename,"
                         "byte_count,width,height,sha256,created_at,expires_at,"
                         "relative_path) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                         -1, &st, NULL) == SQLITE_OK) {
    sqlite3_bind_text(st, 1, id, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, owner, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 3, mime, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 4, clean, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 5, (sqlite3_int64)len);
    sqlite3_bind_int64(st, 6, w);
    sqlite3_bind_int64(st, 7, h);
    sqlite3_bind_text(st, 8, sha, -1, SQLITE_TRANSIENT);
    time_t now = time(NULL);
    sqlite3_bind_int64(st, 9, (sqlite3_int64)now);
    sqlite3_bind_int64(st, 10, (sqlite3_int64)(now + 3600));
    sqlite3_bind_text(st, 11, relative, -1, SQLITE_TRANSIENT);
    rc = sqlite3_step(st) == SQLITE_DONE ? 0 : -1;
  }
  sqlite3_finalize(st);
  pthread_mutex_unlock(&s->mutex);
  if (rc) {
    unlink(path);
    return -1;
  }
  strcpy(out_id, id);
  return 0;
}
int cr_media_store_is_owned(cr_media_store *s, const char *id,
                            const char *owner) {
  if (!s || !id || !owner)
    return 0;
  pthread_mutex_lock(&s->mutex);
  sqlite3_stmt *st = NULL;
  int found = 0;
  if (sqlite3_prepare_v2(s->db,
                         "SELECT 1 FROM media_objects WHERE id=? AND "
                         "owner_account_id=? LIMIT 1",
                         -1, &st, NULL) == SQLITE_OK) {
    sqlite3_bind_text(st, 1, id, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, owner, -1, SQLITE_TRANSIENT);
    found = sqlite3_step(st) == SQLITE_ROW;
  }
  sqlite3_finalize(st);
  pthread_mutex_unlock(&s->mutex);
  return found;
}
int cr_media_store_delete_owned(cr_media_store *s, const char *id,
                                const char *owner) {
  if (!s || !s->db || !id || !owner)
    return -1;
  pthread_mutex_lock(&s->mutex);
  sqlite3_stmt *st = NULL;
  char stored_owner[128] = "", relative[PATH_MAX] = "";
  int found = 0, rc = -1;
  if (sqlite3_prepare_v2(s->db,
                         "SELECT owner_account_id,relative_path FROM media_objects WHERE id=? LIMIT 1",
                         -1, &st, NULL) != SQLITE_OK)
    goto done;
  sqlite3_bind_text(st, 1, id, -1, SQLITE_TRANSIENT);
  if (sqlite3_step(st) == SQLITE_ROW) {
    const char *o = (const char *)sqlite3_column_text(st, 0);
    const char *p = (const char *)sqlite3_column_text(st, 1);
    snprintf(stored_owner, sizeof(stored_owner), "%s", o ? o : "");
    snprintf(relative, sizeof(relative), "%s", p ? p : "");
    found = 1;
  }
  sqlite3_finalize(st);
  st = NULL;
  if (!found || strcasecmp(stored_owner, owner)) {
    rc = 1;
    goto done;
  }
  if (exec_sql(s->db, "BEGIN IMMEDIATE;"))
    goto done;
  if (sqlite3_prepare_v2(s->db,
                         "DELETE FROM media_objects WHERE id=? AND owner_account_id=?",
                         -1, &st, NULL) != SQLITE_OK) {
    (void)exec_sql(s->db, "ROLLBACK;");
    goto done;
  }
  sqlite3_bind_text(st, 1, id, -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(st, 2, owner, -1, SQLITE_TRANSIENT);
  int ok = sqlite3_step(st) == SQLITE_DONE && sqlite3_changes(s->db) == 1;
  sqlite3_finalize(st);
  st = NULL;
  if (!ok || exec_sql(s->db, "COMMIT;")) {
    (void)exec_sql(s->db, "ROLLBACK;");
    goto done;
  }
  if (*relative) {
    char full[PATH_MAX];
    if (join_path(full, sizeof(full), s->objects_root, relative)) {
      rc = -1;
      goto done;
    }
    if (unlink(full) && errno != ENOENT) {
      rc = -1;
      goto done;
    }
  }
  rc = 0;
done:
  sqlite3_finalize(st);
  pthread_mutex_unlock(&s->mutex);
  return rc;
}

int cr_media_store_bind(cr_media_store *s, const char *id, const char *owner,
                        int kind, const char *scope, const char *message,
                        time_t expires) {
  if (!cr_media_store_is_owned(s, id, owner) || !scope || !message)
    return -1;
  pthread_mutex_lock(&s->mutex);
  sqlite3_stmt *st = NULL;
  int rc = -1;
  if (sqlite3_prepare_v2(s->db,
                         "INSERT OR IGNORE INTO "
                         "media_refs(media_id,kind,scope,message_id,created_at,"
                         "expires_at) VALUES(?,?,?,?,?,?)",
                         -1, &st, NULL) == SQLITE_OK) {
    sqlite3_bind_text(st, 1, id, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(st, 2, kind);
    sqlite3_bind_text(st, 3, scope, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 4, message, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 5, (sqlite3_int64)time(NULL));
    if (expires)
      sqlite3_bind_int64(st, 6, (sqlite3_int64)expires);
    else
      sqlite3_bind_null(st, 6);
    rc = sqlite3_step(st) == SQLITE_DONE ? 0 : -1;
  }
  sqlite3_finalize(st);
  if (!rc && sqlite3_prepare_v2(
                 s->db, "UPDATE media_objects SET expires_at=NULL WHERE id=?",
                 -1, &st, NULL) == SQLITE_OK) {
    sqlite3_bind_text(st, 1, id, -1, SQLITE_TRANSIENT);
    rc = sqlite3_step(st) == SQLITE_DONE ? 0 : -1;
  }
  sqlite3_finalize(st);
  pthread_mutex_unlock(&s->mutex);
  return rc;
}
int cr_media_store_has_ref(cr_media_store *s, const char *id, int kind,
                           const char *scope) {
  if (!s || !id || !scope)
    return 0;
  pthread_mutex_lock(&s->mutex);
  sqlite3_stmt *st = NULL;
  int found = 0;
  if (sqlite3_prepare_v2(s->db,
                         "SELECT 1 FROM media_refs WHERE media_id=? AND kind=? "
                         "AND scope=? LIMIT 1",
                         -1, &st, NULL) == SQLITE_OK) {
    sqlite3_bind_text(st, 1, id, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(st, 2, kind);
    sqlite3_bind_text(st, 3, scope, -1, SQLITE_TRANSIENT);
    found = sqlite3_step(st) == SQLITE_ROW;
  }
  sqlite3_finalize(st);
  pthread_mutex_unlock(&s->mutex);
  return found;
}
int cr_media_store_load(cr_media_store *s, const char *id,
                        cr_media_object *out) {
  if (!s || !id || !out)
    return -1;
  memset(out, 0, sizeof(*out));
  pthread_mutex_lock(&s->mutex);
  sqlite3_stmt *st = NULL;
  char rel[PATH_MAX] = "";
  int rc = -1;
  if (sqlite3_prepare_v2(s->db,
                         "SELECT "
                         "owner_account_id,mime_type,filename,byte_count,width,"
                         "height,relative_path FROM media_objects WHERE id=?",
                         -1, &st, NULL) == SQLITE_OK) {
    sqlite3_bind_text(st, 1, id, -1, SQLITE_TRANSIENT);
    if (sqlite3_step(st) == SQLITE_ROW) {
      snprintf(out->id, sizeof(out->id), "%s", id);
      snprintf(out->owner_account_id, sizeof(out->owner_account_id), "%s",
               (const char *)sqlite3_column_text(st, 0));
      snprintf(out->mime_type, sizeof(out->mime_type), "%s",
               (const char *)sqlite3_column_text(st, 1));
      snprintf(out->filename, sizeof(out->filename), "%s",
               (const char *)sqlite3_column_text(st, 2));
      out->data_len = (size_t)sqlite3_column_int64(st, 3);
      out->width = (uint32_t)sqlite3_column_int64(st, 4);
      out->height = (uint32_t)sqlite3_column_int64(st, 5);
      snprintf(rel, sizeof(rel), "%s",
               (const char *)sqlite3_column_text(st, 6));
      rc = 0;
    }
  }
  sqlite3_finalize(st);
  pthread_mutex_unlock(&s->mutex);
  if (rc || !out->data_len || out->data_len > CR_MEDIA_MAX_BYTES)
    return -1;
  char path[PATH_MAX];
  if (join_path(path, sizeof(path), s->objects_root, rel))
    return -1;
  FILE *f = fopen(path, "rb");
  if (!f)
    return -1;
  out->data = malloc(out->data_len);
  if (!out->data) {
    fclose(f);
    return -1;
  }
  size_t n = fread(out->data, 1, out->data_len, f);
  int bad = n != out->data_len || fclose(f);
  if (bad) {
    cr_media_object_free(out);
    return -1;
  }
  return 0;
}
void cr_media_object_free(cr_media_object *o) {
  if (!o)
    return;
  free(o->data);
  memset(o, 0, sizeof(*o));
}
int cr_media_store_remove_refs(cr_media_store *s, int kind, const char *scope,
                               const char *const *messages, size_t n) {
  if (!s || !scope)
    return -1;
  pthread_mutex_lock(&s->mutex);
  int rc = 0;
  if (messages && n) {
    for (size_t i = 0; i < n && !rc; i++) {
      sqlite3_stmt *st = NULL;
      if (sqlite3_prepare_v2(s->db,
                             "DELETE FROM media_refs WHERE kind=? AND scope=? "
                             "AND message_id=?",
                             -1, &st, NULL) != SQLITE_OK) {
        rc = -1;
        break;
      }
      sqlite3_bind_int(st, 1, kind);
      sqlite3_bind_text(st, 2, scope, -1, SQLITE_TRANSIENT);
      sqlite3_bind_text(st, 3, messages[i], -1, SQLITE_TRANSIENT);
      if (sqlite3_step(st) != SQLITE_DONE)
        rc = -1;
      sqlite3_finalize(st);
    }
  } else {
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(s->db,
                           "DELETE FROM media_refs WHERE kind=? AND scope=?",
                           -1, &st, NULL) != SQLITE_OK)
      rc = -1;
    else {
      sqlite3_bind_int(st, 1, kind);
      sqlite3_bind_text(st, 2, scope, -1, SQLITE_TRANSIENT);
      if (sqlite3_step(st) != SQLITE_DONE)
        rc = -1;
    }
    sqlite3_finalize(st);
  }
  if (!rc)
    rc = delete_orphans_locked(s, time(NULL));
  pthread_mutex_unlock(&s->mutex);
  return rc;
}
int cr_media_store_remove_ref(cr_media_store *s, const char *id, int kind,
                              const char *scope, const char *message_id,
                              int *object_deleted) {
  if (!s || !s->db || !id || !scope || !message_id)
    return -1;
  if (object_deleted)
    *object_deleted = 0;
  pthread_mutex_lock(&s->mutex);
  sqlite3_stmt *st = NULL;
  int existed = 0, remains = 0, rc = -1;
  if (sqlite3_prepare_v2(s->db,
                         "SELECT 1 FROM media_objects WHERE id=? LIMIT 1",
                         -1, &st, NULL) != SQLITE_OK)
    goto done;
  sqlite3_bind_text(st, 1, id, -1, SQLITE_TRANSIENT);
  existed = sqlite3_step(st) == SQLITE_ROW;
  sqlite3_finalize(st);
  st = NULL;
  if (sqlite3_prepare_v2(s->db,
                         "DELETE FROM media_refs WHERE media_id=? AND kind=? AND scope=? AND message_id=?",
                         -1, &st, NULL) != SQLITE_OK)
    goto done;
  sqlite3_bind_text(st, 1, id, -1, SQLITE_TRANSIENT);
  sqlite3_bind_int(st, 2, kind);
  sqlite3_bind_text(st, 3, scope, -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(st, 4, message_id, -1, SQLITE_TRANSIENT);
  if (sqlite3_step(st) != SQLITE_DONE)
    goto done;
  sqlite3_finalize(st);
  st = NULL;
  if (delete_orphans_locked(s, time(NULL)))
    goto done;
  if (existed) {
    if (sqlite3_prepare_v2(s->db,
                           "SELECT 1 FROM media_objects WHERE id=? LIMIT 1",
                           -1, &st, NULL) != SQLITE_OK)
      goto done;
    sqlite3_bind_text(st, 1, id, -1, SQLITE_TRANSIENT);
    remains = sqlite3_step(st) == SQLITE_ROW;
    if (object_deleted)
      *object_deleted = !remains;
  }
  rc = 0;
done:
  sqlite3_finalize(st);
  pthread_mutex_unlock(&s->mutex);
  return rc;
}

int cr_media_store_cleanup(cr_media_store *s, time_t now) {
  if (!s || !s->db)
    return -1;
  pthread_mutex_lock(&s->mutex);
  sqlite3_stmt *st = NULL;
  int rc = -1;
  if (sqlite3_prepare_v2(s->db,
                         "DELETE FROM media_refs WHERE expires_at IS NOT NULL "
                         "AND expires_at<=?",
                         -1, &st, NULL) == SQLITE_OK) {
    sqlite3_bind_int64(st, 1, (sqlite3_int64)now);
    rc = sqlite3_step(st) == SQLITE_DONE ? 0 : -1;
  }
  sqlite3_finalize(st);
  if (!rc)
    rc = delete_orphans_locked(s, now);
  pthread_mutex_unlock(&s->mutex);
  return rc;
}

int cr_media_store_prune_news(cr_media_store *s, const char *news_db_path) {
  if (!s || !news_db_path)
    return -1;
  sqlite3 *news = NULL;
  if (sqlite3_open_v2(news_db_path, &news,
                      SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
                      NULL) != SQLITE_OK) {
    if (news)
      sqlite3_close(news);
    return -1;
  }
  pthread_mutex_lock(&s->mutex);
  sqlite3_stmt *refs = NULL, *check = NULL, *del = NULL;
  int rc = -1;
  if (sqlite3_prepare_v2(
          s->db,
          "SELECT media_id,scope,message_id FROM media_refs WHERE kind=?", -1,
          &refs, NULL) != SQLITE_OK)
    goto done;
  if (sqlite3_prepare_v2(news,
                         "SELECT 1 FROM news_articles WHERE group_id=? AND "
                         "article_id=? LIMIT 1",
                         -1, &check, NULL) != SQLITE_OK)
    goto done;
  if (sqlite3_prepare_v2(s->db,
                         "DELETE FROM media_refs WHERE media_id=? AND kind=? "
                         "AND scope=? AND message_id=?",
                         -1, &del, NULL) != SQLITE_OK)
    goto done;
  sqlite3_bind_int(refs, 1, CR_MEDIA_KIND_NEWS);
  int step;
  while ((step = sqlite3_step(refs)) == SQLITE_ROW) {
    const char *media = (const char *)sqlite3_column_text(refs, 0),
               *scope = (const char *)sqlite3_column_text(refs, 1),
               *message = (const char *)sqlite3_column_text(refs, 2);
    if (!media || !scope || !message) {
      rc = -1;
      goto done;
    }
    char *mend = NULL;
    unsigned long aid = strtoul(message, &mend, 10);
    int exists = 0;
    if (mend && !*mend && aid <= UINT32_MAX) {
      sqlite3_reset(check);
      sqlite3_clear_bindings(check);
      sqlite3_bind_text(check, 1, scope, -1, SQLITE_TRANSIENT);
      sqlite3_bind_int64(check, 2, (sqlite3_int64)aid);
      exists = sqlite3_step(check) == SQLITE_ROW;
    }
    if (!exists) {
      sqlite3_reset(del);
      sqlite3_clear_bindings(del);
      sqlite3_bind_text(del, 1, media, -1, SQLITE_TRANSIENT);
      sqlite3_bind_int(del, 2, CR_MEDIA_KIND_NEWS);
      sqlite3_bind_text(del, 3, scope, -1, SQLITE_TRANSIENT);
      sqlite3_bind_text(del, 4, message, -1, SQLITE_TRANSIENT);
      if (sqlite3_step(del) != SQLITE_DONE) {
        rc = -1;
        goto done;
      }
    }
  }
  if (step != SQLITE_DONE)
    goto done;
  rc = delete_orphans_locked(s, time(NULL));
done:
  sqlite3_finalize(del);
  sqlite3_finalize(check);
  sqlite3_finalize(refs);
  pthread_mutex_unlock(&s->mutex);
  sqlite3_close(news);
  return rc;
}
