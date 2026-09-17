#define _POSIX_C_SOURCE 200809L
#include "file_metadata.h"

#include <json-c/json.h>
#include <openssl/evp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int exec_sql(sqlite3 *db, const char *sql) {
  char *e = NULL;
  int rc = sqlite3_exec(db, sql, NULL, NULL, &e);
  if (rc != SQLITE_OK) {
    fprintf(stderr, "carracho-server: file metadata sqlite: %s\n",
            e ? e : sqlite3_errmsg(db));
    sqlite3_free(e);
    return -1;
  }
  return 0;
}
static int prepare(sqlite3 *db, const char *sql, sqlite3_stmt **st) {
  if (sqlite3_prepare_v2(db, sql, -1, st, NULL) != SQLITE_OK) {
    fprintf(stderr, "carracho-server: file metadata prepare: %s\n",
            sqlite3_errmsg(db));
    return -1;
  }
  return 0;
}
static int bind_blob(sqlite3_stmt *st, int i, const void *p, size_t n) {
  int rc = n ? sqlite3_bind_blob(st, i, p, (int)n, SQLITE_TRANSIENT)
             : sqlite3_bind_zeroblob(st, i, 0);
  return rc == SQLITE_OK ? 0 : -1;
}
static int done(sqlite3 *db, sqlite3_stmt *st) {
  if (sqlite3_step(st) != SQLITE_DONE) {
    fprintf(stderr, "carracho-server: file metadata step: %s\n",
            sqlite3_errmsg(db));
    return -1;
  }
  return 0;
}
static int is_descendant(const uint8_t *c, size_t cn, const uint8_t *p,
                         size_t pn) {
  if (cn <= pn)
    return 0;
  if (!pn)
    return 1;
  return !memcmp(c, p, pn) && c[pn] == 1;
}

static int b64_decode(const char *text, uint8_t **out, size_t *out_len) {
  *out = NULL;
  *out_len = 0;
  if (!text || !*text)
    return 0;
  size_t n = strlen(text), cap = (n / 4) * 3 + 3;
  uint8_t *b = malloc(cap);
  if (!b)
    return -1;
  int decoded = EVP_DecodeBlock(b, (const unsigned char *)text, (int)n);
  if (decoded < 0) {
    free(b);
    return -1;
  }
  while (n && text[n - 1] == '=') {
    decoded--;
    n--;
  }
  *out = b;
  *out_len = (size_t)decoded;
  return 0;
}

static int ensure_schema(sqlite3 *db) {
  return exec_sql(
      db, "CREATE TABLE IF NOT EXISTS file_metadata("
          "scope INTEGER NOT NULL CHECK(scope IN (0,1)),"
          "path BLOB NOT NULL,"
          "flags INTEGER NOT NULL DEFAULT 0 CHECK(flags BETWEEN 0 AND 65535),"
          "comment BLOB NOT NULL DEFAULT X'',"
          "finder_info BLOB NOT NULL CHECK(length(finder_info)=16),"
          "created_at TEXT,"
          "label INTEGER NOT NULL DEFAULT 0 CHECK(label BETWEEN 0 AND 7),"
          "PRIMARY KEY(scope,path)) WITHOUT ROWID;");
}

void cr_file_metadata_init(cr_file_metadata *m) { memset(m, 0, sizeof(*m)); }
void cr_file_metadata_free(cr_file_metadata *m) {
  if (m) {
    free(m->comment);
    m->comment = NULL;
    m->comment_len = 0;
  }
}

static int bind_metadata(sqlite3_stmt *st, int scope, const uint8_t *path,
                         size_t path_len, const cr_file_metadata *m) {
  if (m->comment_len > 255 || m->label > 7)
    return -1;
  if (sqlite3_bind_int(st, 1, scope) != SQLITE_OK ||
      bind_blob(st, 2, path, path_len) ||
      sqlite3_bind_int(st, 3, m->flags) != SQLITE_OK ||
      bind_blob(st, 4, m->comment, m->comment_len) ||
      bind_blob(st, 5, m->finder_info, 16))
    return -1;
  if (m->has_created_at) {
    if (sqlite3_bind_text(st, 6, m->created_at, -1, SQLITE_TRANSIENT) !=
        SQLITE_OK)
      return -1;
  } else if (sqlite3_bind_null(st, 6) != SQLITE_OK)
    return -1;
  return sqlite3_bind_int(st, 7, m->label) == SQLITE_OK ? 0 : -1;
}

static int write_metadata(cr_file_metadata_store *s, const uint8_t *path,
                          size_t path_len, const cr_file_metadata *m,
                          int ignore) {
  sqlite3_stmt *st = NULL;
  const char *sql =
      ignore ? "INSERT INTO "
               "file_metadata(scope,path,flags,comment,finder_info,created_at,"
               "label) VALUES(?,?,?,?,?,?,?) ON CONFLICT(scope,path) DO NOTHING"
             : "INSERT INTO "
               "file_metadata(scope,path,flags,comment,finder_info,created_at,"
               "label) VALUES(?,?,?,?,?,?,?) ON CONFLICT(scope,path) DO UPDATE "
               "SET "
               "flags=excluded.flags,comment=excluded.comment,finder_info="
               "excluded.finder_info,created_at=excluded.created_at,label="
               "excluded.label";
  if (prepare(s->db, sql, &st))
    return -1;
  int rc = bind_metadata(st, s->scope, path, path_len, m) || done(s->db, st);
  sqlite3_finalize(st);
  return rc ? -1 : 0;
}

static int migrate_legacy_json(cr_file_metadata_store *s, const char *path) {
  if (!path || !*path || access(path, F_OK) != 0)
    return 0;
  json_object *root = json_object_from_file(path);
  if (!root || !json_object_is_type(root, json_type_object)) {
    if (root)
      json_object_put(root);
    return -1;
  }
  if (exec_sql(s->db, "BEGIN IMMEDIATE TRANSACTION")) {
    json_object_put(root);
    return -1;
  }
  int rc = 0;
  json_object_object_foreach(root, key, obj) {
    if (!json_object_is_type(obj, json_type_object)) {
      rc = -1;
      break;
    }
    uint8_t *legacy_path = NULL, *comment = NULL, *finder = NULL;
    size_t legacy_len = 0, comment_len = 0, finder_len = 0;
    cr_file_metadata m;
    cr_file_metadata_init(&m);
    json_object *v = NULL;
    if (b64_decode(key, &legacy_path, &legacy_len)) {
      rc = -1;
      goto row_done;
    }
    if (json_object_object_get_ex(obj, "flags", &v))
      m.flags = (uint16_t)json_object_get_int(v);
    if (json_object_object_get_ex(obj, "comment", &v) &&
        b64_decode(json_object_get_string(v), &comment, &comment_len)) {
      rc = -1;
      goto row_done;
    }
    m.comment = comment;
    m.comment_len = comment_len;
    comment = NULL;
    if (json_object_object_get_ex(obj, "finderInfo", &v)) {
      if (b64_decode(json_object_get_string(v), &finder, &finder_len) ||
          finder_len != 16) {
        rc = -1;
        goto row_done;
      }
      memcpy(m.finder_info, finder, 16);
    }
    free(finder);
    finder = NULL;
    if (json_object_object_get_ex(obj, "createdAt", &v) &&
        json_object_is_type(v, json_type_string)) {
      snprintf(m.created_at, sizeof(m.created_at), "%s",
               json_object_get_string(v));
      m.has_created_at = 1;
    }
    if (json_object_object_get_ex(obj, "label", &v)) {
      int label = json_object_get_int(v);
      if (label < 0 || label > 7) {
        rc = -1;
        goto row_done;
      }
      m.label = (uint8_t)label;
    }
    if (write_metadata(s, legacy_path, legacy_len, &m, 1))
      rc = -1;
  row_done:
    free(legacy_path);
    free(comment);
    free(finder);
    cr_file_metadata_free(&m);
    if (rc)
      break;
  }
  if (!rc && exec_sql(s->db, "COMMIT"))
    rc = -1;
  else if (rc)
    exec_sql(s->db, "ROLLBACK");
  json_object_put(root);
  if (!rc)
    (void)unlink(path);
  return rc;
}

int cr_file_metadata_store_init(cr_file_metadata_store *s,
                                const char *database_path, int scope,
                                const char *legacy_json_path) {
  if (!s || !database_path ||
      (scope != CR_FILE_METADATA_SCOPE_PUBLISHED &&
       scope != CR_FILE_METADATA_SCOPE_LEGACY))
    return -1;
  memset(s, 0, sizeof(*s));
  s->scope = scope;
  if (pthread_mutex_init(&s->mutex, NULL) != 0)
    return -1;
  int flags =
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX;
  if (sqlite3_open_v2(database_path, &s->db, flags, NULL) != SQLITE_OK) {
    if (s->db)
      sqlite3_close(s->db);
    s->db = NULL;
    pthread_mutex_destroy(&s->mutex);
    return -1;
  }
  sqlite3_busy_timeout(s->db, 5000);
  if (exec_sql(s->db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; "
                      "PRAGMA foreign_keys=ON;") ||
      ensure_schema(s->db) || migrate_legacy_json(s, legacy_json_path)) {
    sqlite3_close(s->db);
    s->db = NULL;
    pthread_mutex_destroy(&s->mutex);
    return -1;
  }
  return 0;
}
void cr_file_metadata_store_destroy(cr_file_metadata_store *s) {
  if (!s)
    return;
  pthread_mutex_lock(&s->mutex);
  if (s->db) {
    sqlite3_close(s->db);
    s->db = NULL;
  }
  pthread_mutex_unlock(&s->mutex);
  pthread_mutex_destroy(&s->mutex);
}

int cr_file_metadata_get(cr_file_metadata_store *s, const uint8_t *path,
                         size_t path_len, cr_file_metadata *out, int *found) {
  if (!s || !out)
    return -1;
  cr_file_metadata_init(out);
  if (found)
    *found = 0;
  pthread_mutex_lock(&s->mutex);
  sqlite3_stmt *st = NULL;
  int rc = -1;
  if (prepare(s->db,
              "SELECT flags,comment,finder_info,created_at,label FROM "
              "file_metadata WHERE scope=? AND path=?",
              &st) ||
      sqlite3_bind_int(st, 1, s->scope) != SQLITE_OK ||
      bind_blob(st, 2, path, path_len))
    goto done;
  int step = sqlite3_step(st);
  if (step == SQLITE_DONE) {
    rc = 0;
    goto done;
  }
  if (step != SQLITE_ROW)
    goto done;
  out->flags = (uint16_t)sqlite3_column_int(st, 0);
  int cn = sqlite3_column_bytes(st, 1);
  if (cn) {
    out->comment = malloc((size_t)cn);
    if (!out->comment)
      goto done;
    memcpy(out->comment, sqlite3_column_blob(st, 1), (size_t)cn);
    out->comment_len = (size_t)cn;
  }
  int fn = sqlite3_column_bytes(st, 2);
  if (fn != 16)
    goto done;
  memcpy(out->finder_info, sqlite3_column_blob(st, 2), 16);
  if (sqlite3_column_type(st, 3) != SQLITE_NULL) {
    const unsigned char *t = sqlite3_column_text(st, 3);
    if (!t || strlen((const char *)t) >= sizeof(out->created_at))
      goto done;
    snprintf(out->created_at, sizeof(out->created_at), "%s", t);
    out->has_created_at = 1;
  }
  int label = sqlite3_column_int(st, 4);
  if (label < 0 || label > 7)
    goto done;
  out->label = (uint8_t)label;
  if (found)
    *found = 1;
  rc = 0;
done:
  if (st)
    sqlite3_finalize(st);
  pthread_mutex_unlock(&s->mutex);
  if (rc)
    cr_file_metadata_free(out);
  return rc;
}

int cr_file_metadata_set(cr_file_metadata_store *s, const uint8_t *path,
                         size_t path_len, const cr_file_metadata *m) {
  if (!s || !m)
    return -1;
  pthread_mutex_lock(&s->mutex);
  int rc = write_metadata(s, path, path_len, m, 0);
  pthread_mutex_unlock(&s->mutex);
  return rc;
}

static int delete_path(cr_file_metadata_store *s, const uint8_t *path,
                       size_t path_len) {
  sqlite3_stmt *st = NULL;
  if (prepare(s->db, "DELETE FROM file_metadata WHERE scope=? AND path=?", &st))
    return -1;
  int rc = sqlite3_bind_int(st, 1, s->scope) != SQLITE_OK ||
           bind_blob(st, 2, path, path_len) || done(s->db, st);
  sqlite3_finalize(st);
  return rc ? -1 : 0;
}

typedef struct metadata_row {
  uint8_t *path;
  size_t path_len;
  cr_file_metadata value;
} metadata_row;
static void rows_free(metadata_row *rows, size_t n) {
  if (!rows)
    return;
  for (size_t i = 0; i < n; i++) {
    free(rows[i].path);
    cr_file_metadata_free(&rows[i].value);
  }
  free(rows);
}
static int load_rows(cr_file_metadata_store *s, metadata_row **out,
                     size_t *out_count) {
  *out = NULL;
  *out_count = 0;
  sqlite3_stmt *st = NULL;
  if (prepare(s->db,
              "SELECT path,flags,comment,finder_info,created_at,label FROM "
              "file_metadata WHERE scope=?",
              &st) ||
      sqlite3_bind_int(st, 1, s->scope) != SQLITE_OK) {
    if (st)
      sqlite3_finalize(st);
    return -1;
  }
  metadata_row *rows = NULL;
  size_t n = 0, cap = 0;
  int rc = 0;
  for (;;) {
    int step = sqlite3_step(st);
    if (step == SQLITE_DONE)
      break;
    if (step != SQLITE_ROW) {
      rc = -1;
      break;
    }
    if (n == cap) {
      size_t nc = cap ? cap * 2 : 32;
      metadata_row *x = realloc(rows, nc * sizeof(*x));
      if (!x) {
        rc = -1;
        break;
      }
      rows = x;
      cap = nc;
    }
    metadata_row *r = &rows[n];
    memset(r, 0, sizeof(*r));
    cr_file_metadata_init(&r->value);
    int pn = sqlite3_column_bytes(st, 0);
    r->path = malloc(pn ? (size_t)pn : 1);
    if (!r->path) {
      rc = -1;
      break;
    }
    if (pn)
      memcpy(r->path, sqlite3_column_blob(st, 0), (size_t)pn);
    r->path_len = (size_t)pn;
    r->value.flags = (uint16_t)sqlite3_column_int(st, 1);
    int cn = sqlite3_column_bytes(st, 2);
    if (cn) {
      r->value.comment = malloc((size_t)cn);
      if (!r->value.comment) {
        rc = -1;
        break;
      }
      memcpy(r->value.comment, sqlite3_column_blob(st, 2), (size_t)cn);
      r->value.comment_len = (size_t)cn;
    }
    int fn = sqlite3_column_bytes(st, 3);
    if (fn != 16) {
      rc = -1;
      break;
    }
    memcpy(r->value.finder_info, sqlite3_column_blob(st, 3), 16);
    if (sqlite3_column_type(st, 4) != SQLITE_NULL) {
      const unsigned char *t = sqlite3_column_text(st, 4);
      if (!t || strlen((const char *)t) >= sizeof(r->value.created_at)) {
        rc = -1;
        break;
      }
      snprintf(r->value.created_at, sizeof(r->value.created_at), "%s", t);
      r->value.has_created_at = 1;
    }
    int label = sqlite3_column_int(st, 5);
    if (label < 0 || label > 7) {
      rc = -1;
      break;
    }
    r->value.label = (uint8_t)label;
    n++;
  }
  sqlite3_finalize(st);
  if (rc) {
    rows_free(rows, n);
    return -1;
  }
  *out = rows;
  *out_count = n;
  return 0;
}

int cr_file_metadata_remove(cr_file_metadata_store *s, const uint8_t *path,
                            size_t path_len, int descendants) {
  if (!s)
    return -1;
  pthread_mutex_lock(&s->mutex);
  int rc = 0;
  if (!descendants) {
    rc = delete_path(s, path, path_len);
    pthread_mutex_unlock(&s->mutex);
    return rc;
  }
  metadata_row *rows = NULL;
  size_t count = 0;
  if (load_rows(s, &rows, &count) ||
      exec_sql(s->db, "BEGIN IMMEDIATE TRANSACTION")) {
    rows_free(rows, count);
    pthread_mutex_unlock(&s->mutex);
    return -1;
  }
  for (size_t i = 0; i < count && !rc; i++)
    if ((rows[i].path_len == path_len &&
         !memcmp(rows[i].path, path, path_len)) ||
        is_descendant(rows[i].path, rows[i].path_len, path, path_len))
      rc = delete_path(s, rows[i].path, rows[i].path_len);
  if (!rc && exec_sql(s->db, "COMMIT"))
    rc = -1;
  else if (rc)
    exec_sql(s->db, "ROLLBACK");
  rows_free(rows, count);
  pthread_mutex_unlock(&s->mutex);
  return rc;
}

int cr_file_metadata_move(cr_file_metadata_store *s, const uint8_t *src,
                          size_t sl, const uint8_t *dst, size_t dl,
                          int descendants) {
  if (!s)
    return -1;
  pthread_mutex_lock(&s->mutex);
  metadata_row *rows = NULL;
  size_t count = 0;
  if (load_rows(s, &rows, &count) ||
      exec_sql(s->db, "BEGIN IMMEDIATE TRANSACTION")) {
    rows_free(rows, count);
    pthread_mutex_unlock(&s->mutex);
    return -1;
  }
  int rc = 0;
  for (size_t i = 0; i < count && !rc; i++) {
    metadata_row *r = &rows[i];
    int exact = r->path_len == sl && !memcmp(r->path, src, sl),
        child = descendants && is_descendant(r->path, r->path_len, src, sl);
    if (exact || child)
      rc = delete_path(s, r->path, r->path_len);
  }
  for (size_t i = 0; i < count && !rc; i++) {
    metadata_row *r = &rows[i];
    int exact = r->path_len == sl && !memcmp(r->path, src, sl),
        child = descendants && is_descendant(r->path, r->path_len, src, sl);
    if (!exact && !child)
      continue;
    size_t suffix = exact ? 0 : r->path_len - sl, mapped_len = dl + suffix;
    uint8_t *mapped = malloc(mapped_len ? mapped_len : 1);
    if (!mapped) {
      rc = -1;
      break;
    }
    if (dl)
      memcpy(mapped, dst, dl);
    if (suffix)
      memcpy(mapped + dl, r->path + sl, suffix);
    rc = write_metadata(s, mapped, mapped_len, &r->value, 0);
    free(mapped);
  }
  if (!rc && exec_sql(s->db, "COMMIT"))
    rc = -1;
  else if (rc)
    exec_sql(s->db, "ROLLBACK");
  rows_free(rows, count);
  pthread_mutex_unlock(&s->mutex);
  return rc;
}
