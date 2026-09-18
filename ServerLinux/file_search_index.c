#define _POSIX_C_SOURCE 200809L
#include "file_search_index.h"
#include "carracho_protocol.h"
#include "server_state.h"
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <time.h>

#define CR_FILE_INDEX_SCHEMA 1
#define CR_FILE_INDEX_MAX_RESULTS 100000u
#define CR_MAC_EPOCH_OFFSET 2082844800ULL

static int exec_sql(sqlite3 *db,const char *sql){return sqlite3_exec(db,sql,NULL,NULL,NULL)==SQLITE_OK?0:-1;}
static sqlite3_int64 pragma_int64(sqlite3 *db,const char *sql){sqlite3_stmt*st=NULL;sqlite3_int64 value=-1;if(sqlite3_prepare_v2(db,sql,-1,&st,NULL)==SQLITE_OK&&sqlite3_step(st)==SQLITE_ROW)value=sqlite3_column_int64(st,0);sqlite3_finalize(st);return value;}
static void compact_after_full_rebuild(sqlite3 *db){sqlite3_int64 pages=pragma_int64(db,"PRAGMA page_count"),free_pages=pragma_int64(db,"PRAGMA freelist_count");if(pages>0&&free_pages>=256&&free_pages*4>=pages)(void)exec_sql(db,"VACUUM");(void)sqlite3_wal_checkpoint_v2(db,NULL,SQLITE_CHECKPOINT_TRUNCATE,NULL,NULL);}
static uint32_t mac_time(time_t t){if(t<0)return 0;uint64_t v=(uint64_t)t+CR_MAC_EPOCH_OFFSET;return v>UINT32_MAX?UINT32_MAX:(uint32_t)v;}
static int is_transfer_staging_name(const char*s){size_t n=strlen(s);return (n>=9&&!strcmp(s+n-9,".carracho"))||!strncmp(s,".carracho.",10);}
static int glob_matches_name(const char*pattern,const char*name){
    const char*star=NULL,*retry=NULL;
    while(*name){if(*pattern=='*'){star=pattern++;retry=name;continue;}if(*pattern=='?'||*pattern==*name){pattern++;name++;continue;}if(star){pattern=star+1;name=++retry;continue;}return 0;}while(*pattern=='*')pattern++;return *pattern=='\0';
}
static int exclusion_matches_name(const cr_search_index_exclusions *exclusions,const char *name){
    if(!exclusions||!name)return 0;
    for(size_t i=0;i<exclusions->count;i++)if(glob_matches_name(exclusions->patterns[i],name))return 1;
    return 0;
}
static int exclusion_matches_legacy_path(const cr_search_index_exclusions *exclusions,const uint8_t *path,size_t n){
    if(!exclusions||!exclusions->count||!path||!n)return 0;
    size_t start=0;
    for(size_t i=0;i<=n;i++){
        if(i<n&&path[i]!=1)continue;
        size_t len=i-start;
        if(len){char component[1024];if(!cr_macroman_to_utf8(path+start,len,component,sizeof(component))&&exclusion_matches_name(exclusions,component))return 1;}
        start=i+1;
    }
    return 0;
}

static char *path_key(const uint8_t *path,size_t n){
    static const char hex[]="0123456789ABCDEF";char *out=malloc(n*2+1);if(!out)return NULL;
    for(size_t i=0;i<n;i++){out[i*2]=hex[path[i]>>4];out[i*2+1]=hex[path[i]&15];}out[n*2]='\0';return out;
}
static char *ascii_fold(const char *s){size_t n=strlen(s);char *out=malloc(n+1);if(!out)return NULL;for(size_t i=0;i<n;i++){unsigned char c=(unsigned char)s[i];out[i]=(char)(c<128?tolower(c):c);}out[n]='\0';return out;}
static int append_child(const uint8_t *parent,size_t pl,const uint8_t *name,size_t nl,uint8_t *out,size_t *ol){
    size_t need=pl+(pl?1:0)+nl;if(!nl||need>4096)return-1;if(pl)memcpy(out,parent,pl);size_t p=pl;if(pl)out[p++]=1;memcpy(out+p,name,nl);*ol=need;return 0;
}
static int is_dropbox(cr_file_metadata_store *m,const uint8_t *path,size_t n){cr_file_metadata x;int found=0,drop=0;cr_file_metadata_init(&x);if(!m||cr_file_metadata_get(m,path,n,&x,&found)){cr_file_metadata_free(&x);return 0;}drop=found&&((x.flags&0x2000u)!=0);cr_file_metadata_free(&x);return drop;}
static int is_inside_dropbox(cr_file_metadata_store *m,const uint8_t *path,size_t n){
    if(!m||!path||!n)return 0;
    for(size_t i=0;i<=n;i++){
        if(i<n&&path[i]!=1)continue;
        if(i&&is_dropbox(m,path,i))return 1;
    }
    return 0;
}

static int create_schema(sqlite3 *db){
    if(exec_sql(db,"PRAGMA foreign_keys=ON")||exec_sql(db,"PRAGMA journal_mode=WAL")||exec_sql(db,"PRAGMA synchronous=NORMAL"))return-1;
    if(exec_sql(db,"CREATE TABLE IF NOT EXISTS entries(path_key TEXT PRIMARY KEY,path BLOB NOT NULL,name BLOB NOT NULL,name_search TEXT NOT NULL,comment_search TEXT NOT NULL DEFAULT '',is_folder INTEGER NOT NULL CHECK(is_folder IN (0,1)),size INTEGER NOT NULL,timestamp INTEGER NOT NULL)"))return-1;
    if(exec_sql(db,"CREATE TABLE IF NOT EXISTS trigrams(term TEXT NOT NULL,path_key TEXT NOT NULL REFERENCES entries(path_key) ON DELETE CASCADE,PRIMARY KEY(term,path_key)) WITHOUT ROWID"))return-1;
    if(exec_sql(db,"CREATE INDEX IF NOT EXISTS trigrams_term_idx ON trigrams(term,path_key)"))return-1;
    if(exec_sql(db,"CREATE TABLE IF NOT EXISTS index_meta(key TEXT PRIMARY KEY,value INTEGER NOT NULL) WITHOUT ROWID"))return-1;
    char pragma[64];snprintf(pragma,sizeof(pragma),"PRAGMA user_version=%d",CR_FILE_INDEX_SCHEMA);return exec_sql(db,pragma);
}

int cr_file_search_index_init(cr_file_search_index *idx, const char *path) {
  if (!idx || !path || strlen(path) + 1 > sizeof(idx->path))
    return -1;
  memset(idx, 0, sizeof(*idx));
  strcpy(idx->path, path);
  if (pthread_mutex_init(&idx->mutex, NULL))
    return -1;
  if (sqlite3_open_v2(path, &idx->db,
                      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE |
                          SQLITE_OPEN_FULLMUTEX,
                      NULL) != SQLITE_OK) {
    if (idx->db)
      sqlite3_close(idx->db);
    idx->db = NULL;
    pthread_mutex_destroy(&idx->mutex);
    return -1;
  }
  sqlite3_busy_timeout(idx->db, 5000);
  if (create_schema(idx->db)) {
    sqlite3_close(idx->db);
    idx->db = NULL;
    pthread_mutex_destroy(&idx->mutex);
    return -1;
  }
  idx->ready = 1;
  return 0;
}
void cr_file_search_index_destroy(cr_file_search_index *idx){if(!idx||!idx->ready)return;pthread_mutex_lock(&idx->mutex);if(idx->db)sqlite3_close(idx->db);idx->db=NULL;idx->ready=0;pthread_mutex_unlock(&idx->mutex);pthread_mutex_destroy(&idx->mutex);}

static int delete_subtree_locked(cr_file_search_index *idx,const uint8_t *path,size_t n){
    char *key=path_key(path,n);if(!key)return-1;size_t pn=strlen(key)+4;char *prefix=malloc(pn);if(!prefix){free(key);return-1;}snprintf(prefix,pn,"%s01%%",key);
    sqlite3_stmt *st=NULL;int rc=-1;if(sqlite3_prepare_v2(idx->db,"DELETE FROM entries WHERE path_key=? OR path_key LIKE ?",-1,&st,NULL)!=SQLITE_OK)goto done;
    sqlite3_bind_text(st,1,key,-1,SQLITE_TRANSIENT);sqlite3_bind_text(st,2,prefix,-1,SQLITE_TRANSIENT);if(sqlite3_step(st)==SQLITE_DONE)rc=0;
done:sqlite3_finalize(st);free(prefix);free(key);return rc;
}

static int insert_entry_locked(cr_file_search_index *idx, const uint8_t *path,
                               size_t pl, const uint8_t *name, size_t nl,
                               const char *name_utf8, int folder, uint32_t size,
                               uint32_t timestamp,
                               cr_file_metadata_store *metadata) {
  char *key = path_key(path, pl), *fold = ascii_fold(name_utf8),
       comment_utf8[2048] = "", *comment_fold = NULL;
  if (!key || !fold) {
    free(key);
    free(fold);
    return -1;
  }
  if (metadata) {
    cr_file_metadata m;
    int found = 0;
    cr_file_metadata_init(&m);
    if (!cr_file_metadata_get(metadata, path, pl, &m, &found) && found &&
        m.comment_len) {
      if (cr_macroman_to_utf8(m.comment, m.comment_len, comment_utf8,
                              sizeof(comment_utf8)))
        comment_utf8[0] = '\0';
    }
    cr_file_metadata_free(&m);
  }
  comment_fold = ascii_fold(comment_utf8);
  if (!comment_fold) {
    free(key);
    free(fold);
    return -1;
  }
  sqlite3_stmt *st = NULL;
  int rc = -1;
  if (sqlite3_prepare_v2(
          idx->db,
          "INSERT OR REPLACE INTO "
          "entries(path_key,path,name,name_search,comment_search,is_folder,"
          "size,timestamp) VALUES(?,?,?,?,?,?,?,?)",
          -1, &st, NULL) != SQLITE_OK)
    goto done;
  sqlite3_bind_text(st, 1, key, -1, SQLITE_TRANSIENT);
  sqlite3_bind_blob(st, 2, path, (int)pl, SQLITE_TRANSIENT);
  sqlite3_bind_blob(st, 3, name, (int)nl, SQLITE_TRANSIENT);
  sqlite3_bind_text(st, 4, fold, -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(st, 5, comment_fold, -1, SQLITE_TRANSIENT);
  sqlite3_bind_int(st, 6, folder);
  sqlite3_bind_int64(st, 7, (sqlite3_int64)size);
  sqlite3_bind_int64(st, 8, (sqlite3_int64)timestamp);
  if (sqlite3_step(st) != SQLITE_DONE)
    goto done;
  sqlite3_finalize(st);
  st = NULL;
  if (sqlite3_prepare_v2(idx->db, "DELETE FROM trigrams WHERE path_key=?", -1,
                         &st, NULL) != SQLITE_OK)
    goto done;
  sqlite3_bind_text(st, 1, key, -1, SQLITE_TRANSIENT);
  if (sqlite3_step(st) != SQLITE_DONE)
    goto done;
  sqlite3_finalize(st);
  st = NULL;
  size_t fn = strlen(fold);
  if (fn >= 3) {
    if (sqlite3_prepare_v2(
            idx->db,
            "INSERT OR IGNORE INTO trigrams(term,path_key) VALUES(?,?)", -1,
            &st, NULL) != SQLITE_OK)
      goto done;
    for (size_t i = 0; i + 2 < fn; i++) {
      char gram[4] = {fold[i], fold[i + 1], fold[i + 2], 0};
      sqlite3_reset(st);
      sqlite3_clear_bindings(st);
      sqlite3_bind_text(st, 1, gram, 3, SQLITE_TRANSIENT);
      sqlite3_bind_text(st, 2, key, -1, SQLITE_TRANSIENT);
      if (sqlite3_step(st) != SQLITE_DONE)
        goto done;
    }
  }
  rc = 0;
done:
  sqlite3_finalize(st);
  free(comment_fold);
  free(fold);
  free(key);
  return rc;
}

typedef struct cr_index_directory_identity { dev_t device; ino_t inode; } cr_index_directory_identity;
typedef struct cr_index_visited { cr_index_directory_identity *items; size_t count; size_t capacity; } cr_index_visited;

static void visited_free(cr_index_visited *visited){if(!visited)return;free(visited->items);memset(visited,0,sizeof(*visited));}
static int visited_add(cr_index_visited *visited,const struct stat *st){
    if(!visited||!st)return-1;
    for(size_t i=0;i<visited->count;i++)if(visited->items[i].device==st->st_dev&&visited->items[i].inode==st->st_ino)return 0;
    if(visited->count==visited->capacity){size_t next=visited->capacity?visited->capacity*2:128;cr_index_directory_identity *items=realloc(visited->items,next*sizeof(*items));if(!items)return-1;visited->items=items;visited->capacity=next;}
    visited->items[visited->count++]=(cr_index_directory_identity){st->st_dev,st->st_ino};return 1;
}

static int scan_item_locked(cr_file_search_index *idx,const char *fs,const uint8_t *path,size_t pl,cr_file_metadata_store *metadata,const cr_search_index_exclusions *exclusions,cr_index_visited *visited,int recurse,const volatile sig_atomic_t *stop);
static int scan_children_locked(cr_file_search_index *idx, const char *dir,
                                const uint8_t *parent, size_t pl,
                                cr_file_metadata_store *metadata,
                                const cr_search_index_exclusions *exclusions,
                                cr_index_visited *visited,
                                const volatile sig_atomic_t *stop) {
  if (stop && *stop)
    return -2;
  DIR *d = opendir(dir);
  if (!d)
    return -1;
  char **names = NULL;
  size_t count = 0, cap = 0;
  struct dirent *de;
  int rc = 0;
  while ((de = readdir(d))) {
    if (stop && *stop) {
      rc = -2;
      break;
    }
    if (de->d_name[0] == '.' || is_transfer_staging_name(de->d_name) ||
        exclusion_matches_name(exclusions, de->d_name))
      continue;
    if (count == cap) {
      size_t nc = cap ? cap * 2 : 32;
      char **nn = realloc(names, nc * sizeof(*nn));
      if (!nn) {
        rc = -1;
        break;
      }
      names = nn;
      cap = nc;
    }
    names[count] = strdup(de->d_name);
    if (!names[count++]) {
      rc = -1;
      break;
    }
  }
  closedir(d);
  if (rc)
    goto done;
  for (size_t i = 0; i < count; i++) {
    if (stop && *stop) {
      rc = -2;
      goto done;
    }
    for (size_t j = i + 1; j < count; j++)
      if (strcasecmp(names[i], names[j]) > 0) {
        char *t = names[i];
        names[i] = names[j];
        names[j] = t;
      }
  }
  for (size_t i = 0; i < count && !rc; i++) {
    if (stop && *stop) {
      rc = -2;
      break;
    }
    char childfs[PATH_MAX];
    int n = snprintf(childfs, sizeof(childfs), "%s/%s", dir, names[i]);
    if (n < 0 || (size_t)n >= sizeof(childfs))
      continue;
    uint8_t name[512];
    size_t nl = 0;
    if (cr_utf8_to_macroman(names[i], name, sizeof(name), &nl) || !nl ||
        nl > 255)
      continue;
    uint8_t path[4096];
    size_t path_len = 0;
    if (append_child(parent, pl, name, nl, path, &path_len))
      continue;
    int child_rc = scan_item_locked(idx, childfs, path, path_len, metadata,
                                    exclusions, visited, 1, stop);
    if (child_rc)
      rc = child_rc;
  }
done:
  if (names) {
    for (size_t i = 0; i < count; i++)
      free(names[i]);
    free(names);
  }
  return rc;
}
static int scan_item_locked(cr_file_search_index *idx, const char *fs,
                            const uint8_t *path, size_t pl,
                            cr_file_metadata_store *metadata,
                            const cr_search_index_exclusions *exclusions,
                            cr_index_visited *visited, int recurse,
                            const volatile sig_atomic_t *stop) {
  if (stop && *stop)
    return -2;
  if (exclusion_matches_legacy_path(exclusions, path, pl))
    return 0;
  struct stat st;
  if (stat(fs, &st) || (!S_ISREG(st.st_mode) && !S_ISDIR(st.st_mode)))
    return 0;
  const char *leaf = strrchr(fs, '/');
  leaf = leaf ? leaf + 1 : fs;
  if (!*leaf || leaf[0] == '.' || is_transfer_staging_name(leaf) ||
      exclusion_matches_name(exclusions, leaf))
    return 0;
  uint8_t name[512];
  size_t nl = 0;
  if (cr_utf8_to_macroman(leaf, name, sizeof(name), &nl) || !nl || nl > 255)
    return 0;
  int folder = S_ISDIR(st.st_mode);
  /*
   * Dropbox trees are write-only/private storage from the search index's point
   * of view. Check every legacy-path prefix so direct incremental upserts of a
   * file inside a Dropbox cannot bypass the full-rebuild recursion guard.
   */
  if (is_inside_dropbox(metadata, path, pl))
    return 0;
  uint64_t raw = folder ? 0 : (uint64_t)(st.st_size < 0 ? 0 : st.st_size);
  uint32_t size = raw > UINT32_MAX ? UINT32_MAX : (uint32_t)raw;
  if (insert_entry_locked(idx, path, pl, name, nl, leaf, folder, size,
                          mac_time(st.st_mtime), metadata))
    return -1;
  if (folder && recurse) {
    int added = visited_add(visited, &st);
    if (added < 0)
      return -1;
    if (!added)
      return 0;
    return scan_children_locked(idx, fs, path, pl, metadata, exclusions,
                                visited, stop);
  }
  return 0;
}

int cr_file_search_index_rebuild_interruptible(
    cr_file_search_index *idx, const char *root,
    cr_file_metadata_store *metadata,
    const cr_search_index_exclusions *exclusions,
    const volatile sig_atomic_t *stop) {
  if (!idx || !idx->ready)
    return -1;
  pthread_mutex_lock(&idx->mutex);
  int rc = -1;
  cr_index_visited visited = {0};
  if (stop && *stop) {
    rc = -2;
    goto done;
  }
  if (exec_sql(idx->db, "BEGIN IMMEDIATE"))
    goto done;
  if (exec_sql(idx->db, "DELETE FROM trigrams") ||
      exec_sql(idx->db, "DELETE FROM entries")) {
    exec_sql(idx->db, "ROLLBACK");
    goto done;
  }
  struct stat root_st;
  if (stat(root, &root_st) == 0 && S_ISDIR(root_st.st_mode) &&
      visited_add(&visited, &root_st) < 0) {
    exec_sql(idx->db, "ROLLBACK");
    goto done;
  }
  int scan_rc = scan_children_locked(idx, root, NULL, 0, metadata, exclusions,
                                     &visited, stop);
  if (scan_rc) {
    exec_sql(idx->db, "ROLLBACK");
    rc = scan_rc;
    goto done;
  }
  char meta_sql[384];long long rebuilt_at=(long long)time(NULL);
  snprintf(meta_sql,sizeof(meta_sql),
           "INSERT INTO index_meta(key,value) VALUES('last_full_rebuild_unix',%lld) "
           "ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
           "INSERT INTO index_meta(key,value) VALUES('schedule_anchor_unix',%lld) "
           "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
           rebuilt_at,rebuilt_at);
  if (exec_sql(idx->db, meta_sql) || exec_sql(idx->db, "COMMIT"))
    goto done;
  /* Reclaim substantial stale index space, then truncate the rebuild WAL. */
  compact_after_full_rebuild(idx->db);
  rc = 0;
done:
  visited_free(&visited);
  pthread_mutex_unlock(&idx->mutex);
  return rc;
}

int cr_file_search_index_rebuild(cr_file_search_index *idx,const char *root,cr_file_metadata_store *metadata,const cr_search_index_exclusions *exclusions){return cr_file_search_index_rebuild_interruptible(idx,root,metadata,exclusions,NULL);}

int cr_file_search_index_upsert_subtree(cr_file_search_index *idx,const char *fs,const uint8_t *path,size_t n,cr_file_metadata_store *metadata,const cr_search_index_exclusions *exclusions){if(!idx||!idx->ready)return-1;pthread_mutex_lock(&idx->mutex);cr_index_visited visited={0};int rc=-1;if(exec_sql(idx->db,"BEGIN IMMEDIATE"))goto done;if(delete_subtree_locked(idx,path,n)||scan_item_locked(idx,fs,path,n,metadata,exclusions,&visited,1,NULL)){exec_sql(idx->db,"ROLLBACK");goto done;}if(exec_sql(idx->db,"COMMIT"))goto done;rc=0;done:visited_free(&visited);pthread_mutex_unlock(&idx->mutex);return rc;}
int cr_file_search_index_remove_subtree(cr_file_search_index *idx,const uint8_t *path,size_t n){if(!idx||!idx->ready)return-1;pthread_mutex_lock(&idx->mutex);int rc=delete_subtree_locked(idx,path,n);pthread_mutex_unlock(&idx->mutex);return rc;}
int cr_file_search_index_move_subtree(cr_file_search_index *idx,const uint8_t *src,size_t sl,const uint8_t *dst,size_t dl,const char *dfs,cr_file_metadata_store *metadata,const cr_search_index_exclusions *exclusions){if(!idx||!idx->ready)return-1;pthread_mutex_lock(&idx->mutex);cr_index_visited visited={0};int rc=-1;if(exec_sql(idx->db,"BEGIN IMMEDIATE"))goto done;if(delete_subtree_locked(idx,src,sl)||delete_subtree_locked(idx,dst,dl)||scan_item_locked(idx,dfs,dst,dl,metadata,exclusions,&visited,1,NULL)){exec_sql(idx->db,"ROLLBACK");goto done;}if(exec_sql(idx->db,"COMMIT"))goto done;rc=0;done:visited_free(&visited);pthread_mutex_unlock(&idx->mutex);return rc;}

int cr_file_search_index_entry_count(cr_file_search_index *idx, uint64_t *count) {
    if (count)
        *count = 0;
    if (!idx || !idx->ready)
        return -1;

    pthread_mutex_lock(&idx->mutex);
    sqlite3_stmt *st = NULL;
    int rc = -1;

    if (sqlite3_prepare_v2(idx->db, "SELECT COUNT(*) FROM entries", -1, &st, NULL) == SQLITE_OK &&
        sqlite3_step(st) == SQLITE_ROW) {
        sqlite3_int64 value = sqlite3_column_int64(st, 0);
        if (count)
            *count = value > 0 ? (uint64_t)value : 0;
        rc = 0;
    }

    sqlite3_finalize(st);
    pthread_mutex_unlock(&idx->mutex);
    return rc;
}

int cr_file_search_index_last_full_rebuild(cr_file_search_index *idx, int64_t *timestamp, int *found) {
    if (timestamp)
        *timestamp = 0;
    if (found)
        *found = 0;
    if (!idx || !idx->ready)
        return -1;

    pthread_mutex_lock(&idx->mutex);
    sqlite3_stmt *st = NULL;
    int rc = -1;

    if (sqlite3_prepare_v2(idx->db,
                           "SELECT value FROM index_meta WHERE key='last_full_rebuild_unix'",
                           -1, &st, NULL) == SQLITE_OK) {
        int step = sqlite3_step(st);
        if (step == SQLITE_ROW) {
            if (timestamp)
                *timestamp = sqlite3_column_int64(st, 0);
            if (found)
                *found = 1;
            rc = 0;
        } else if (step == SQLITE_DONE) {
            rc = 0;
        }
    }

    sqlite3_finalize(st);
    pthread_mutex_unlock(&idx->mutex);
    return rc;
}

int cr_file_search_index_rebuild_schedule_reference(cr_file_search_index *idx,
                                                     int64_t now,
                                                     int64_t *timestamp) {
    if (timestamp)
        *timestamp = now;
    if (!idx || !idx->ready)
        return -1;

    pthread_mutex_lock(&idx->mutex);
    sqlite3_stmt *st = NULL;
    int rc = -1;
    int64_t value = 0;
    int found = 0;
    const char *keys[] = {"last_full_rebuild_unix", "schedule_anchor_unix"};

    for (size_t k = 0; k < 2 && !found; k++) {
        if (sqlite3_prepare_v2(idx->db,
                               "SELECT value FROM index_meta WHERE key=?",
                               -1, &st, NULL) != SQLITE_OK)
            goto done;

        sqlite3_bind_text(st, 1, keys[k], -1, SQLITE_STATIC);
        int step = sqlite3_step(st);
        if (step == SQLITE_ROW) {
            value = sqlite3_column_int64(st, 0);
            found = 1;
        } else if (step != SQLITE_DONE) {
            sqlite3_finalize(st);
            st = NULL;
            goto done;
        }

        sqlite3_finalize(st);
        st = NULL;
    }

    if (!found) {
        if (sqlite3_prepare_v2(idx->db,
                               "INSERT INTO index_meta(key,value) VALUES('schedule_anchor_unix',?)",
                               -1, &st, NULL) != SQLITE_OK)
            goto done;

        sqlite3_bind_int64(st, 1, now);
        if (sqlite3_step(st) != SQLITE_DONE)
            goto done;
        value = now;
    }

    if (timestamp)
        *timestamp = value;
    rc = 0;

done:
    sqlite3_finalize(st);
    pthread_mutex_unlock(&idx->mutex);
    return rc;
}

int cr_file_search_index_search(cr_file_search_index *idx, const char *query,
                                const cr_search_index_exclusions *exclusions,
                                cr_file_search_index_callback cb, void *ctx,
                                size_t *result_count) {
  if (result_count)
    *result_count = 0;
  if (!idx || !idx->ready || !query || !*query || !cb)
    return -1;
  char *fold = ascii_fold(query);
  if (!fold)
    return -1;
  size_t qn = strlen(fold), grams = qn >= 3 ? qn - 2 : 0;
  size_t cap = 512 + grams * 96;
  char *sql = malloc(cap);
  if (!sql) {
    free(fold);
    return -1;
  }
  strcpy(sql, "SELECT e.path,e.name,e.is_folder,e.size,e.timestamp FROM "
              "entries e WHERE instr(e.name_search,?)>0");
  if (grams) {
    for (size_t i = 0; i < grams; i++)
      strcat(sql, " AND EXISTS(SELECT 1 FROM trigrams t WHERE "
                  "t.path_key=e.path_key AND t.term=?)");
  }
  strcat(sql, " ORDER BY e.path_key LIMIT ?");
  pthread_mutex_lock(&idx->mutex);
  sqlite3_stmt *st = NULL;
  int rc = -1;
  if (sqlite3_prepare_v2(idx->db, sql, -1, &st, NULL) != SQLITE_OK)
    goto done;
  int bi = 1;
  sqlite3_bind_text(st, bi++, fold, -1, SQLITE_TRANSIENT);
  for (size_t i = 0; i < grams; i++) {
    sqlite3_bind_text(st, bi++, fold + i, 3, SQLITE_TRANSIENT);
  }
  sqlite3_bind_int(st, bi, (int)CR_FILE_INDEX_MAX_RESULTS + 1);
  size_t count = 0;
  for (;;) {
    int step = sqlite3_step(st);
    if (step == SQLITE_DONE) {
      rc = 0;
      break;
    }
    if (step != SQLITE_ROW)
      break;
    if (++count > CR_FILE_INDEX_MAX_RESULTS)
      break;
    const void *pb = sqlite3_column_blob(st, 0),
               *nb = sqlite3_column_blob(st, 1);
    int pl = sqlite3_column_bytes(st, 0), nl = sqlite3_column_bytes(st, 1);
    if (pl < 0 || pl > 4096 || nl <= 0 || nl > 255 || (!pb && pl) || !nb)
      break;
    cr_file_search_index_result r;
    memset(&r, 0, sizeof(r));
    if (pl)
      memcpy(r.path, pb, (size_t)pl);
    memcpy(r.name, nb, (size_t)nl);
    r.path_len = (size_t)pl;
    r.name_len = (size_t)nl;
    r.is_folder = sqlite3_column_int(st, 2) != 0;
    sqlite3_int64 sz = sqlite3_column_int64(st, 3),
                  ts = sqlite3_column_int64(st, 4);
    r.size = sz < 0 ? 0 : sz > UINT32_MAX ? UINT32_MAX : (uint32_t)sz;
    r.timestamp = ts < 0 ? 0 : ts > UINT32_MAX ? UINT32_MAX : (uint32_t)ts;
    if (exclusion_matches_legacy_path(exclusions, r.path, r.path_len)) {
      count--;
      continue;
    }
    if (cb(ctx, &r))
      break;
  }
  if (rc == 0 && result_count)
    *result_count = count;
done:
  sqlite3_finalize(st);
  pthread_mutex_unlock(&idx->mutex);
  free(sql);
  free(fold);
  return rc;
}
