#define _POSIX_C_SOURCE 200809L
#include "sqlite_state.h"

#include <stdint.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CR_DB_SCHEMA_VERSION 4

static int exec_sql(sqlite3 *db, const char *sql) {
    char *error = NULL;
    int rc = sqlite3_exec(db, sql, NULL, NULL, &error);
    if (rc != SQLITE_OK) {
        fprintf(stderr, "carracho-server: sqlite: %s\n", error ? error : sqlite3_errmsg(db));
        sqlite3_free(error);
        return -1;
    }
    return 0;
}

static int prepare(sqlite3 *db, const char *sql, sqlite3_stmt **stmt) {
    if (sqlite3_prepare_v2(db, sql, -1, stmt, NULL) != SQLITE_OK) {
        fprintf(stderr, "carracho-server: sqlite prepare: %s\n", sqlite3_errmsg(db));
        return -1;
    }
    return 0;
}

static int bind_text(sqlite3_stmt *stmt, int index, const char *text) {
    return sqlite3_bind_text(stmt, index, text ? text : "", -1, SQLITE_TRANSIENT) == SQLITE_OK ? 0 : -1;
}

static int step_done(sqlite3 *db, sqlite3_stmt *stmt) {
    if (sqlite3_step(stmt) != SQLITE_DONE) {
        fprintf(stderr, "carracho-server: sqlite step: %s\n", sqlite3_errmsg(db));
        return -1;
    }
    return 0;
}

static int create_schema(sqlite3 *db) {
    static const char *sql =
        "PRAGMA foreign_keys=ON;"
        "CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);"
        "CREATE TABLE IF NOT EXISTS settings(section TEXT PRIMARY KEY,json TEXT NOT NULL);"
        "CREATE TABLE IF NOT EXISTS accounts(id TEXT PRIMARY KEY,login TEXT NOT NULL COLLATE NOCASE UNIQUE,sort_order INTEGER NOT NULL,json TEXT NOT NULL);"
        "CREATE INDEX IF NOT EXISTS accounts_login_idx ON accounts(login COLLATE NOCASE);"
        "CREATE TABLE IF NOT EXISTS newsgroups(id TEXT PRIMARY KEY,name TEXT NOT NULL COLLATE NOCASE UNIQUE,sort_order INTEGER NOT NULL,json TEXT NOT NULL);"
        "CREATE INDEX IF NOT EXISTS newsgroups_name_idx ON newsgroups(name COLLATE NOCASE);"
        "CREATE TABLE IF NOT EXISTS statistics(name TEXT PRIMARY KEY,value INTEGER NOT NULL CHECK(value >= 0));"
        "CREATE TABLE IF NOT EXISTS account_transfer_statistics(account_id TEXT PRIMARY KEY,login TEXT NOT NULL,download_count INTEGER NOT NULL DEFAULT 0 CHECK(download_count >= 0),download_bytes INTEGER NOT NULL DEFAULT 0 CHECK(download_bytes >= 0),upload_count INTEGER NOT NULL DEFAULT 0 CHECK(upload_count >= 0),upload_bytes INTEGER NOT NULL DEFAULT 0 CHECK(upload_bytes >= 0));"
        "CREATE INDEX IF NOT EXISTS account_transfer_statistics_login_idx ON account_transfer_statistics(login COLLATE NOCASE);"
        "CREATE TABLE IF NOT EXISTS offline_messages(id TEXT PRIMARY KEY,recipient_account_id TEXT NOT NULL,created_at INTEGER NOT NULL,nonce BLOB NOT NULL,ciphertext BLOB NOT NULL,tag BLOB NOT NULL);"
        "CREATE INDEX IF NOT EXISTS offline_messages_recipient_idx ON offline_messages(recipient_account_id,created_at,id);"
        "CREATE TABLE IF NOT EXISTS file_metadata(scope INTEGER NOT NULL CHECK(scope IN (0,1)),path BLOB NOT NULL,flags INTEGER NOT NULL DEFAULT 0 CHECK(flags BETWEEN 0 AND 65535),comment BLOB NOT NULL DEFAULT X'',finder_info BLOB NOT NULL CHECK(length(finder_info)=16),created_at TEXT,label INTEGER NOT NULL DEFAULT 0 CHECK(label BETWEEN 0 AND 7),PRIMARY KEY(scope,path)) WITHOUT ROWID;";
    if (exec_sql(db, sql)) return -1;
    char pragma[64];
    snprintf(pragma, sizeof(pragma), "PRAGMA user_version=%d", CR_DB_SCHEMA_VERSION);
    return exec_sql(db, pragma);
}

int cr_sqlite_state_open(sqlite3 **out, const char *path) {
    *out = NULL;
    int flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX;
    if (sqlite3_open_v2(path, out, flags, NULL) != SQLITE_OK) {
        fprintf(stderr, "carracho-server: sqlite open %s: %s\n", path, *out ? sqlite3_errmsg(*out) : "unknown error");
        if (*out) sqlite3_close(*out);
        *out = NULL;
        return -1;
    }
    sqlite3_busy_timeout(*out, 5000);
    if (exec_sql(*out, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;") || create_schema(*out)) {
        sqlite3_close(*out);
        *out = NULL;
        return -1;
    }
    return 0;
}

int cr_sqlite_state_has_state(sqlite3 *db) {
    sqlite3_stmt *stmt = NULL;
    if (prepare(db, "SELECT 1 FROM meta WHERE key='state_format_version' LIMIT 1", &stmt)) return -1;
    int rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    if (rc == SQLITE_ROW) return 1;
    if (rc == SQLITE_DONE) return 0;
    fprintf(stderr, "carracho-server: sqlite state check: %s\n", sqlite3_errmsg(db));
    return -1;
}

static int insert_pair(sqlite3 *db, const char *sql, const char *a, const char *b) {
    sqlite3_stmt *stmt = NULL;
    if (prepare(db, sql, &stmt)) return -1;
    int rc = bind_text(stmt, 1, a) || bind_text(stmt, 2, b) || step_done(db, stmt);
    sqlite3_finalize(stmt);
    return rc ? -1 : 0;
}

static int insert_json_setting(sqlite3 *db, const char *section, json_object *value) {
    const char *json = json_object_to_json_string_ext(value, JSON_C_TO_STRING_PLAIN);
    return insert_pair(db, "INSERT INTO settings(section,json) VALUES(?,?)", section, json);
}

static int insert_json_rows(sqlite3 *db, const char *table, json_object *array, const char *name_key) {
    char sql[256];
    if (snprintf(sql, sizeof(sql), "INSERT INTO %s(id,%s,sort_order,json) VALUES(?,?,?,?)", table, name_key) >= (int)sizeof(sql)) return -1;
    sqlite3_stmt *stmt = NULL;
    if (prepare(db, sql, &stmt)) return -1;
    size_t n = array && json_object_is_type(array, json_type_array) ? json_object_array_length(array) : 0;
    for (size_t i = 0; i < n; ++i) {
        json_object *row = json_object_array_get_idx(array, i), *idv = NULL, *namev = NULL;
        if (!row || !json_object_object_get_ex(row, "id", &idv) || !json_object_object_get_ex(row, name_key, &namev)) {
            sqlite3_finalize(stmt);
            return -1;
        }
        const char *id = json_object_get_string(idv), *name = json_object_get_string(namev);
        const char *json = json_object_to_json_string_ext(row, JSON_C_TO_STRING_PLAIN);
        sqlite3_reset(stmt); sqlite3_clear_bindings(stmt);
        if (bind_text(stmt, 1, id) || bind_text(stmt, 2, name) ||
            sqlite3_bind_int64(stmt, 3, (sqlite3_int64)i) != SQLITE_OK || bind_text(stmt, 4, json) || step_done(db, stmt)) {
            sqlite3_finalize(stmt);
            return -1;
        }
    }
    sqlite3_finalize(stmt);
    return 0;
}

int cr_sqlite_sync_account_transfer_rows(sqlite3 *db, json_object *accounts) {
    sqlite3_stmt *stmt = NULL;
    if (prepare(db, "INSERT INTO account_transfer_statistics(account_id,login,download_count,download_bytes,upload_count,upload_bytes) VALUES(?,?,0,0,0,0) ON CONFLICT(account_id) DO UPDATE SET login=excluded.login", &stmt)) return -1;
    size_t n = accounts && json_object_is_type(accounts, json_type_array) ? json_object_array_length(accounts) : 0;
    for (size_t i = 0; i < n; ++i) {
        json_object *row = json_object_array_get_idx(accounts, i), *idv = NULL, *loginv = NULL;
        if (!row || !json_object_object_get_ex(row, "id", &idv) || !json_object_object_get_ex(row, "login", &loginv)) { sqlite3_finalize(stmt); return -1; }
        sqlite3_reset(stmt); sqlite3_clear_bindings(stmt);
        if (bind_text(stmt, 1, json_object_get_string(idv)) || bind_text(stmt, 2, json_object_get_string(loginv)) || step_done(db, stmt)) { sqlite3_finalize(stmt); return -1; }
    }
    sqlite3_finalize(stmt);
    return 0;
}

int cr_sqlite_state_save(sqlite3 *db, json_object *root) {
    if (!db || !root) return -1;
    if (exec_sql(db, "BEGIN IMMEDIATE TRANSACTION")) return -1;
    int failed = 0;
    do {
        if (exec_sql(db, "DELETE FROM meta;DELETE FROM settings;DELETE FROM accounts;DELETE FROM newsgroups;DELETE FROM statistics;")) { failed = 1; break; }
        json_object *v = NULL;
        int format = json_object_object_get_ex(root, "formatVersion", &v) ? json_object_get_int(v) : 2;
        char format_text[32]; snprintf(format_text, sizeof(format_text), "%d", format);
        if (insert_pair(db, "INSERT INTO meta(key,value) VALUES(?,?)", "schema_version", "3") ||
            insert_pair(db, "INSERT INTO meta(key,value) VALUES(?,?)", "state_format_version", format_text)) { failed = 1; break; }

        static const char *sections[] = { "authentication", "identity", "advanced", "agreement" };
        for (size_t i = 0; i < sizeof(sections)/sizeof(sections[0]); ++i) {
            if (!json_object_object_get_ex(root, sections[i], &v) || insert_json_setting(db, sections[i], v)) { failed = 1; break; }
        }
        if (failed) break;
        json_object *account_groups = NULL;
        if (!json_object_object_get_ex(root, "accountGroups", &account_groups) || !json_object_is_type(account_groups, json_type_array)) {
            account_groups = json_object_new_array();
            if (!account_groups) { failed = 1; break; }
            json_object_object_add(root, "accountGroups", account_groups);
        }
        if (insert_json_setting(db, "accountGroups", account_groups)) { failed = 1; break; }
        json_object *runtime = NULL;
        if (!json_object_object_get_ex(root, "runtime", &runtime) || !json_object_is_type(runtime, json_type_object)) {
            runtime = json_object_new_object();
            if (!runtime) { failed = 1; break; }
            json_object_object_add(runtime, "filesRoot", json_object_new_string(""));
            json_object_object_add(runtime, "legacyFilesRoot", json_object_new_string(""));
            json_object_object_add(runtime, "uploadBandwidthLimitBytesPerSecond", json_object_new_int64(0));
            json_object_object_add(runtime, "searchIndexExclusions", json_object_new_array());
            json_object_object_add(root, "runtime", runtime);
        }
        if (insert_json_setting(db, "runtime", runtime)) { failed = 1; break; }

        json_object *accounts = NULL, *groups = NULL;
        if (!json_object_object_get_ex(root, "accounts", &accounts) || insert_json_rows(db, "accounts", accounts, "login") || cr_sqlite_sync_account_transfer_rows(db, accounts)) { failed = 1; break; }
        if (!json_object_object_get_ex(root, "newsgroups", &groups) || insert_json_rows(db, "newsgroups", groups, "name")) { failed = 1; break; }

        json_object *stats = NULL;
        if (!json_object_object_get_ex(root, "statistics", &stats) || !json_object_is_type(stats, json_type_object)) { failed = 1; break; }
        sqlite3_stmt *stmt = NULL;
        if (prepare(db, "INSERT INTO statistics(name,value) VALUES(?,?)", &stmt)) { failed = 1; break; }
        json_object_object_foreach(stats, key, value) {
            int64_t amount = json_object_get_int64(value);
            if (amount < 0) amount = 0;
            sqlite3_reset(stmt); sqlite3_clear_bindings(stmt);
            if (bind_text(stmt, 1, key) || sqlite3_bind_int64(stmt, 2, amount) != SQLITE_OK || step_done(db, stmt)) { failed = 1; break; }
        }
        sqlite3_finalize(stmt);
    } while (0);

    if (failed) {
        exec_sql(db, "ROLLBACK");
        return -1;
    }
    if (exec_sql(db, "COMMIT")) { exec_sql(db, "ROLLBACK"); return -1; }
    return 0;
}

int cr_sqlite_record_account_transfer(sqlite3 *db, const char *account_id, const char *login, int is_download, uint64_t bytes) {
    if (!db || !account_id || !*account_id || !login) return -1;
    if (exec_sql(db, "BEGIN IMMEDIATE TRANSACTION")) return -1;
    sqlite3_stmt *stmt = NULL;
    int failed = 0;
    if (prepare(db, "INSERT INTO account_transfer_statistics(account_id,login,download_count,download_bytes,upload_count,upload_bytes) VALUES(?,?,0,0,0,0) ON CONFLICT(account_id) DO UPDATE SET login=excluded.login", &stmt) ||
        bind_text(stmt, 1, account_id) || bind_text(stmt, 2, login) || step_done(db, stmt)) failed = 1;
    if (stmt) { sqlite3_finalize(stmt); stmt = NULL; }
    if (!failed) {
        const char *sql = is_download
            ? "UPDATE account_transfer_statistics SET download_count=CASE WHEN download_count>=9223372036854775807 THEN 9223372036854775807 ELSE download_count+1 END,download_bytes=CASE WHEN download_bytes>9223372036854775807-? THEN 9223372036854775807 ELSE download_bytes+? END WHERE account_id=?"
            : "UPDATE account_transfer_statistics SET upload_count=CASE WHEN upload_count>=9223372036854775807 THEN 9223372036854775807 ELSE upload_count+1 END,upload_bytes=CASE WHEN upload_bytes>9223372036854775807-? THEN 9223372036854775807 ELSE upload_bytes+? END WHERE account_id=?";
        sqlite3_int64 amount = bytes > (uint64_t)INT64_MAX ? INT64_MAX : (sqlite3_int64)bytes;
        if (prepare(db, sql, &stmt) || sqlite3_bind_int64(stmt,1,amount)!=SQLITE_OK || sqlite3_bind_int64(stmt,2,amount)!=SQLITE_OK || bind_text(stmt,3,account_id) || step_done(db,stmt)) failed=1;
        if (stmt) { sqlite3_finalize(stmt); stmt=NULL; }
    }
    if (failed) { exec_sql(db,"ROLLBACK"); return -1; }
    if (exec_sql(db,"COMMIT")) { exec_sql(db,"ROLLBACK"); return -1; }
    return 0;
}


int cr_sqlite_account_transfer_statistics(sqlite3 *db, const char *account_id,
                                          uint64_t *download_count, uint64_t *download_bytes,
                                          uint64_t *upload_count, uint64_t *upload_bytes) {
    if (!db || !account_id || !*account_id || !download_count || !download_bytes || !upload_count || !upload_bytes) return -1;
    *download_count = *download_bytes = *upload_count = *upload_bytes = 0;
    sqlite3_stmt *stmt = NULL;
    if (prepare(db, "SELECT download_count,download_bytes,upload_count,upload_bytes FROM account_transfer_statistics WHERE account_id=?", &stmt) ||
        bind_text(stmt, 1, account_id)) {
        if (stmt) sqlite3_finalize(stmt);
        return -1;
    }
    int rc = sqlite3_step(stmt);
    if (rc == SQLITE_ROW) {
        sqlite3_int64 dc = sqlite3_column_int64(stmt, 0);
        sqlite3_int64 dbv = sqlite3_column_int64(stmt, 1);
        sqlite3_int64 uc = sqlite3_column_int64(stmt, 2);
        sqlite3_int64 ub = sqlite3_column_int64(stmt, 3);
        *download_count = dc < 0 ? 0 : (uint64_t)dc;
        *download_bytes = dbv < 0 ? 0 : (uint64_t)dbv;
        *upload_count = uc < 0 ? 0 : (uint64_t)uc;
        *upload_bytes = ub < 0 ? 0 : (uint64_t)ub;
    } else if (rc != SQLITE_DONE) {
        fprintf(stderr, "carracho-server: sqlite step: %s\n", sqlite3_errmsg(db));
        sqlite3_finalize(stmt);
        return -1;
    }
    sqlite3_finalize(stmt);
    return 0;
}


static void lowercase_id(const char *src, char out[128]) {
    size_t n = strlen(src); if (n > 127) n = 127;
    for (size_t i=0;i<n;i++) out[i]=(char)tolower((unsigned char)src[i]);
    out[n]=0;
}

static int offline_key_path(sqlite3 *db, char out[PATH_MAX]) {
  const char *dbpath = sqlite3_db_filename(db, "main");
  if (!dbpath || !*dbpath)
    return -1;
  const char *slash = strrchr(dbpath, '/');
  if (!slash)
    return snprintf(out, PATH_MAX, "./server-message.key") >= PATH_MAX ? -1 : 0;
  size_t dir = (size_t)(slash - dbpath);
  const char *leaf = "/server-message.key";
  size_t ln = strlen(leaf);
  if (dir + ln + 1 > PATH_MAX)
    return -1;
  memcpy(out, dbpath, dir);
  memcpy(out + dir, leaf, ln + 1);
  return 0;
}

static int load_offline_key(sqlite3 *db, uint8_t key[32]) {
    char path[PATH_MAX]; if(offline_key_path(db,path))return-1;
    int fd=open(path,O_RDONLY); if(fd>=0){ssize_t n=read(fd,key,32);uint8_t extra;ssize_t e=read(fd,&extra,1);close(fd);return n==32&&e==0?0:-1;}
    if(errno!=ENOENT)return-1;
    if(RAND_bytes(key,32)!=1)return-1;
    fd=open(path,O_WRONLY|O_CREAT|O_EXCL,0600);
    if(fd<0){if(errno==EEXIST)return load_offline_key(db,key);return-1;}
    size_t off=0;while(off<32){ssize_t n=write(fd,key+off,32-off);if(n<=0){close(fd);unlink(path);return-1;}off+=(size_t)n;}
    if(close(fd)){unlink(path);return-1;}return 0;
}

static int make_offline_id(char out[37]) {
    uint8_t b[16];if(RAND_bytes(b,sizeof(b))!=1)return-1;b[6]=(uint8_t)((b[6]&0x0f)|0x40);b[8]=(uint8_t)((b[8]&0x3f)|0x80);
    snprintf(out,37,"%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]);return 0;
}

static int make_offline_aad(const char *id,const char *recipient,uint8_t **out,size_t *out_len){
    char rid[128];lowercase_id(recipient,rid);const char *prefix="CarrachoOfflineMessage/v1|";size_t n=strlen(prefix)+strlen(id)+1+strlen(rid);uint8_t *p=malloc(n+1);if(!p)return-1;int w=snprintf((char*)p,n+1,"%s%s|%s",prefix,id,rid);if(w<0||(size_t)w!=n){free(p);return-1;}*out=p;*out_len=n;return 0;
}

static int aes_gcm_encrypt(sqlite3 *db,const char *id,const char *recipient,const uint8_t *plain,size_t plain_len,uint8_t nonce[12],uint8_t **cipher,int *cipher_len,uint8_t tag[16]){
    uint8_t key[32],*aad=NULL;size_t aad_len=0;if(load_offline_key(db,key)||make_offline_aad(id,recipient,&aad,&aad_len)||RAND_bytes(nonce,12)!=1)return-1;
    EVP_CIPHER_CTX *ctx=EVP_CIPHER_CTX_new();uint8_t *out=malloc(plain_len?plain_len:1);int len=0,total=0,ok=ctx&&out;
    if(ok)ok=EVP_EncryptInit_ex(ctx,EVP_aes_256_gcm(),NULL,NULL,NULL)==1;
    if(ok)ok=EVP_CIPHER_CTX_ctrl(ctx,EVP_CTRL_GCM_SET_IVLEN,12,NULL)==1;
    if(ok)ok=EVP_EncryptInit_ex(ctx,NULL,NULL,key,nonce)==1;
    if(ok)ok=EVP_EncryptUpdate(ctx,NULL,&len,aad,(int)aad_len)==1;
    if(ok)ok=EVP_EncryptUpdate(ctx,out,&len,plain,(int)plain_len)==1,total=len;
    if(ok)ok=EVP_EncryptFinal_ex(ctx,out+total,&len)==1,total+=len;
    if(ok)ok=EVP_CIPHER_CTX_ctrl(ctx,EVP_CTRL_GCM_GET_TAG,16,tag)==1;
    EVP_CIPHER_CTX_free(ctx);OPENSSL_cleanse(key,sizeof(key));free(aad);if(!ok){free(out);return-1;}*cipher=out;*cipher_len=total;return 0;
}

static int aes_gcm_decrypt(sqlite3 *db, const char *id, const char *recipient,
                           const uint8_t *nonce, size_t nonce_len,
                           const uint8_t *cipher, size_t cipher_len,
                           const uint8_t *tag, size_t tag_len, uint8_t **plain,
                           size_t *plain_len) {
  if (nonce_len != 12 || tag_len != 16 || cipher_len > 65536)
    return -1;
  uint8_t key[32], *aad = NULL;
  size_t aad_len = 0;
  if (load_offline_key(db, key) ||
      make_offline_aad(id, recipient, &aad, &aad_len))
    return -1;
  EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
  uint8_t *out = malloc(cipher_len ? cipher_len : 1);
  int len = 0, total = 0, ok = ctx && out;
  if (ok)
    ok = EVP_DecryptInit_ex(ctx, EVP_aes_256_gcm(), NULL, NULL, NULL) == 1;
  if (ok)
    ok = EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, 12, NULL) == 1;
  if (ok)
    ok = EVP_DecryptInit_ex(ctx, NULL, NULL, key, nonce) == 1;
  if (ok)
    ok = EVP_DecryptUpdate(ctx, NULL, &len, aad, (int)aad_len) == 1;
  if (ok)
    ok = EVP_DecryptUpdate(ctx, out, &len, cipher, (int)cipher_len) == 1,
    total = len;
  if (ok)
    ok = EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, 16, (void *)tag) == 1;
  if (ok)
    ok = EVP_DecryptFinal_ex(ctx, out + total, &len) == 1, total += len;
  EVP_CIPHER_CTX_free(ctx);
  OPENSSL_cleanse(key, sizeof(key));
  free(aad);
  if (!ok) {
    free(out);
    return -1;
  }
  *plain = out;
  *plain_len = (size_t)total;
  return 0;
}

int cr_sqlite_offline_message_put(sqlite3 *db, const char *recipient_account_id,
                                  const uint8_t *plaintext,
                                  size_t plaintext_len, uint64_t created_at,
                                  char out_id[37]) {
  if (!db || !recipient_account_id || !*recipient_account_id || !plaintext ||
      !plaintext_len || plaintext_len > 65536)
    return -1;
  char id[37];
  if (make_offline_id(id))
    return -1;
  uint8_t nonce[12], tag[16], *cipher = NULL;
  int cipher_len = 0;
  if (aes_gcm_encrypt(db, id, recipient_account_id, plaintext, plaintext_len,
                      nonce, &cipher, &cipher_len, tag))
    return -1;
  char rid[128];
  lowercase_id(recipient_account_id, rid);
  sqlite3_stmt *stmt = NULL;
  int rc = -1;
  if (!prepare(db,
               "INSERT INTO "
               "offline_messages(id,recipient_account_id,created_at,nonce,"
               "ciphertext,tag) VALUES(?,?,?,?,?,?)",
               &stmt) &&
      !bind_text(stmt, 1, id) && !bind_text(stmt, 2, rid) &&
      sqlite3_bind_int64(
          stmt, 3,
          (sqlite3_int64)(created_at > INT64_MAX ? INT64_MAX : created_at)) ==
          SQLITE_OK &&
      sqlite3_bind_blob(stmt, 4, nonce, 12, SQLITE_TRANSIENT) == SQLITE_OK &&
      sqlite3_bind_blob(stmt, 5, cipher, cipher_len, SQLITE_TRANSIENT) ==
          SQLITE_OK &&
      sqlite3_bind_blob(stmt, 6, tag, 16, SQLITE_TRANSIENT) == SQLITE_OK &&
      !step_done(db, stmt)) {
    snprintf(out_id, 37, "%s", id);
    rc = 0;
  }
  if (stmt)
    sqlite3_finalize(stmt);
  free(cipher);
  return rc;
}

int cr_sqlite_offline_message_count(sqlite3 *db,
                                    const char *recipient_account_id,
                                    size_t *out_count) {
  if (!db || !recipient_account_id || !out_count)
    return -1;
  char rid[128];
  lowercase_id(recipient_account_id, rid);
  sqlite3_stmt *stmt = NULL;
  if (prepare(
          db,
          "SELECT COUNT(*) FROM offline_messages WHERE recipient_account_id=?",
          &stmt) ||
      bind_text(stmt, 1, rid)) {
    if (stmt)
      sqlite3_finalize(stmt);
    return -1;
  }
  int rc = sqlite3_step(stmt);
  if (rc != SQLITE_ROW) {
    sqlite3_finalize(stmt);
    return -1;
  }
  sqlite3_int64 n = sqlite3_column_int64(stmt, 0);
  sqlite3_finalize(stmt);
  *out_count = n < 0 ? 0 : (size_t)n;
  return 0;
}

int cr_sqlite_offline_message_load(sqlite3 *db,
                                   const char *recipient_account_id,
                                   cr_offline_message_blob **out_messages,
                                   size_t *out_count) {
  if (!db || !recipient_account_id || !out_messages || !out_count)
    return -1;
  *out_messages = NULL;
  *out_count = 0;
  char rid[128];
  lowercase_id(recipient_account_id, rid);
  sqlite3_stmt *stmt = NULL;
  if (prepare(db,
              "SELECT id,created_at,nonce,ciphertext,tag FROM offline_messages "
              "WHERE recipient_account_id=? ORDER BY created_at,id",
              &stmt) ||
      bind_text(stmt, 1, rid)) {
    if (stmt)
      sqlite3_finalize(stmt);
    return -1;
  }
  size_t count = 0, cap = 0;
  cr_offline_message_blob *items = NULL;
  int failed = 0;
  while (1) {
    int step = sqlite3_step(stmt);
    if (step == SQLITE_DONE)
      break;
    if (step != SQLITE_ROW) {
      failed = 1;
      break;
    }
    if (count == cap) {
      size_t nc = cap ? cap * 2 : 8;
      cr_offline_message_blob *ni = realloc(items, nc * sizeof(*ni));
      if (!ni) {
        failed = 1;
        break;
      }
      items = ni;
      cap = nc;
    }
    cr_offline_message_blob *x = &items[count];
    memset(x, 0, sizeof(*x));
    const unsigned char *id = sqlite3_column_text(stmt, 0);
    const uint8_t *nonce = sqlite3_column_blob(stmt, 2),
                  *cipher = sqlite3_column_blob(stmt, 3),
                  *tag = sqlite3_column_blob(stmt, 4);
    int nn = sqlite3_column_bytes(stmt, 2), cn = sqlite3_column_bytes(stmt, 3),
        tn = sqlite3_column_bytes(stmt, 4);
    if (!id || strlen((const char *)id) >= sizeof(x->id) ||
        aes_gcm_decrypt(db, (const char *)id, rid, nonce, (size_t)nn, cipher,
                        (size_t)cn, tag, (size_t)tn, &x->plaintext,
                        &x->plaintext_len)) {
      failed = 1;
      break;
    }
    snprintf(x->id, sizeof(x->id), "%s", id);
    sqlite3_int64 created = sqlite3_column_int64(stmt, 1);
    x->created_at = created < 0 ? 0 : (uint64_t)created;
    count++;
  }
  sqlite3_finalize(stmt);
  if (failed) {
    cr_sqlite_offline_message_free(items, count);
    return -1;
  }
  *out_messages = items;
  *out_count = count;
  return 0;
}

void cr_sqlite_offline_message_free(cr_offline_message_blob *messages,size_t count){if(!messages)return;for(size_t i=0;i<count;i++){if(messages[i].plaintext){OPENSSL_cleanse(messages[i].plaintext,messages[i].plaintext_len);free(messages[i].plaintext);}}free(messages);}

int cr_sqlite_offline_message_ack(sqlite3 *db, const char *recipient_account_id,
                                  const char *const *ids, size_t count) {
  if (!db || !recipient_account_id || !ids || !count)
    return -1;
  char rid[128];
  lowercase_id(recipient_account_id, rid);
  if (exec_sql(db, "BEGIN IMMEDIATE TRANSACTION"))
    return -1;
  sqlite3_stmt *stmt = NULL;
  int failed = prepare(
      db, "DELETE FROM offline_messages WHERE recipient_account_id=? AND id=?",
      &stmt);
  for (size_t i = 0; !failed && i < count; i++) {
    sqlite3_reset(stmt);
    sqlite3_clear_bindings(stmt);
    char id[128];
    lowercase_id(ids[i], id);
    if (bind_text(stmt, 1, rid) || bind_text(stmt, 2, id) ||
        step_done(db, stmt))
      failed = 1;
  }
  if (stmt)
    sqlite3_finalize(stmt);
  if (failed) {
    exec_sql(db, "ROLLBACK");
    return -1;
  }
  if (exec_sql(db, "COMMIT")) {
    exec_sql(db, "ROLLBACK");
    return -1;
  }
  return 0;
}

static json_object *parse_column_json(sqlite3_stmt *stmt, int column) {
    const unsigned char *text = sqlite3_column_text(stmt, column);
    return text ? json_tokener_parse((const char *)text) : NULL;
}

static json_object *load_setting(sqlite3 *db, const char *section) {
    sqlite3_stmt *stmt = NULL;
    if (prepare(db, "SELECT json FROM settings WHERE section=?", &stmt)) return NULL;
    if (bind_text(stmt, 1, section)) { sqlite3_finalize(stmt); return NULL; }
    json_object *result = NULL;
    if (sqlite3_step(stmt) == SQLITE_ROW) result = parse_column_json(stmt, 0);
    sqlite3_finalize(stmt);
    return result;
}

static json_object *load_json_rows(sqlite3 *db, const char *table, const char *order_column) {
    char sql[256];
    if (snprintf(sql, sizeof(sql), "SELECT json FROM %s ORDER BY sort_order,%s COLLATE NOCASE", table, order_column) >= (int)sizeof(sql)) return NULL;
    sqlite3_stmt *stmt = NULL;
    if (prepare(db, sql, &stmt)) return NULL;
    json_object *array = json_object_new_array();
    if (!array) { sqlite3_finalize(stmt); return NULL; }
    for (;;) {
        int rc = sqlite3_step(stmt);
        if (rc == SQLITE_DONE) break;
        if (rc != SQLITE_ROW) { json_object_put(array); sqlite3_finalize(stmt); return NULL; }
        json_object *row = parse_column_json(stmt, 0);
        if (!row) { json_object_put(array); sqlite3_finalize(stmt); return NULL; }
        json_object_array_add(array, row);
    }
    sqlite3_finalize(stmt);
    return array;
}

json_object *cr_sqlite_state_load(sqlite3 *db) {
    if (!db) return NULL;
    json_object *root = json_object_new_object();
    if (!root) return NULL;

    sqlite3_stmt *stmt = NULL;
    if (prepare(db, "SELECT value FROM meta WHERE key='state_format_version'", &stmt)) goto fail;
    int format = 2;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        const unsigned char *text = sqlite3_column_text(stmt, 0);
        if (text) format = atoi((const char *)text);
    } else { sqlite3_finalize(stmt); goto fail; }
    sqlite3_finalize(stmt); stmt = NULL;
    json_object_object_add(root, "formatVersion", json_object_new_int(format));

    static const char *sections[] = { "authentication", "identity", "advanced", "agreement" };
    for (size_t i = 0; i < sizeof(sections)/sizeof(sections[0]); ++i) {
        json_object *value = load_setting(db, sections[i]);
        if (!value) goto fail;
        json_object_object_add(root, sections[i], value);
    }
    json_object *account_groups = load_setting(db, "accountGroups");
    if (!account_groups) account_groups = json_object_new_array();
    if (!account_groups) goto fail;
    json_object_object_add(root, "accountGroups", account_groups);

    json_object *runtime = load_setting(db, "runtime");
    if (!runtime) {
        runtime = json_object_new_object();
        if (!runtime) goto fail;
        json_object_object_add(runtime, "filesRoot", json_object_new_string(""));
        json_object_object_add(runtime, "uploadBandwidthLimitBytesPerSecond", json_object_new_int64(0));
        json_object_object_add(runtime, "searchIndexExclusions", json_object_new_array());
    }
    json_object_object_add(root, "runtime", runtime);

    json_object *accounts = load_json_rows(db, "accounts", "login");
    json_object *groups = load_json_rows(db, "newsgroups", "name");
    if (!accounts || !groups) { if (accounts) json_object_put(accounts); if (groups) json_object_put(groups); goto fail; }
    json_object_object_add(root, "accounts", accounts);
    json_object_object_add(root, "newsgroups", groups);

    json_object *stats = json_object_new_object();
    if (!stats) goto fail;
    if (prepare(db, "SELECT name,value FROM statistics", &stmt)) { json_object_put(stats); goto fail; }
    for (;;) {
        int rc = sqlite3_step(stmt);
        if (rc == SQLITE_DONE) break;
        if (rc != SQLITE_ROW) { sqlite3_finalize(stmt); stmt = NULL; json_object_put(stats); goto fail; }
        const unsigned char *name = sqlite3_column_text(stmt, 0);
        int64_t value = sqlite3_column_int64(stmt, 1);
        if (name) json_object_object_add(stats, (const char *)name, json_object_new_int64(value < 0 ? 0 : value));
    }
    sqlite3_finalize(stmt); stmt = NULL;
    json_object_object_add(root, "statistics", stats);
    return root;

fail:
    if (stmt) sqlite3_finalize(stmt);
    json_object_put(root);
    fprintf(stderr, "carracho-server: sqlite load failed: %s\n", sqlite3_errmsg(db));
    return NULL;
}
