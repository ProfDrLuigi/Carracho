#define _POSIX_C_SOURCE 200809L
#include "flat_news_store.h"
#include <errno.h>
#include <json-c/json.h>
#include <openssl/evp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int exec_sql(sqlite3*db,const char*sql){char*e=NULL;int rc=sqlite3_exec(db,sql,NULL,NULL,&e);if(rc!=SQLITE_OK){if(e)sqlite3_free(e);return-1;}return 0;}
static int ensure_schema(sqlite3*db){sqlite3_busy_timeout(db,5000);if(exec_sql(db,"PRAGMA journal_mode=WAL;PRAGMA synchronous=NORMAL;PRAGMA foreign_keys=ON;"))return-1;return exec_sql(db,"CREATE TABLE IF NOT EXISTS news_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);CREATE TABLE IF NOT EXISTS news_group_sequences(group_id TEXT PRIMARY KEY,next_article_id INTEGER NOT NULL);CREATE TABLE IF NOT EXISTS news_articles(group_id TEXT NOT NULL,article_id INTEGER NOT NULL,subject BLOB NOT NULL,sender BLOB NOT NULL,legacy_date INTEGER NOT NULL,created_at REAL NOT NULL,body BLOB NOT NULL,parent_article_id INTEGER NOT NULL,thread_id INTEGER NOT NULL,PRIMARY KEY(group_id,article_id));CREATE TABLE IF NOT EXISTS news_reactions(group_id TEXT NOT NULL,article_id INTEGER NOT NULL,account_id TEXT NOT NULL,reaction INTEGER NOT NULL,PRIMARY KEY(group_id,article_id,account_id),FOREIGN KEY(group_id,article_id) REFERENCES news_articles(group_id,article_id) ON DELETE CASCADE);CREATE TABLE IF NOT EXISTS flat_news(sequence INTEGER PRIMARY KEY AUTOINCREMENT,entry BLOB NOT NULL);INSERT OR IGNORE INTO news_meta(key,value) VALUES('schema_version','1');");}
static int meta_exists(sqlite3*db,const char*k){sqlite3_stmt*st=NULL;if(sqlite3_prepare_v2(db,"SELECT 1 FROM news_meta WHERE key=?",-1,&st,NULL)!=SQLITE_OK)return-1;sqlite3_bind_text(st,1,k,-1,SQLITE_TRANSIENT);int x=sqlite3_step(st),r=x==SQLITE_ROW?1:x==SQLITE_DONE?0:-1;sqlite3_finalize(st);return r;}
static int set_meta(sqlite3*db,const char*k){sqlite3_stmt*st=NULL;if(sqlite3_prepare_v2(db,"INSERT OR REPLACE INTO news_meta(key,value) VALUES(?,'1')",-1,&st,NULL)!=SQLITE_OK)return-1;sqlite3_bind_text(st,1,k,-1,SQLITE_TRANSIENT);int r=sqlite3_step(st)==SQLITE_DONE?0:-1;sqlite3_finalize(st);return r;}
static int b64d(const char*s,uint8_t**out,size_t*n){*out=NULL;*n=0;if(!s||!*s)return-1;size_t l=strlen(s),c=(l/4)*3+3;uint8_t*b=malloc(c);if(!b)return-1;int x=EVP_DecodeBlock(b,(const unsigned char*)s,(int)l);if(x<0){free(b);return-1;}while(l&&s[l-1]=='='){x--;l--;}if(x<=0||x>UINT16_MAX){free(b);return-1;}*out=b;*n=(size_t)x;return 0;}
static int migrate_legacy(cr_flat_news_store*s){int has=meta_exists(s->db,"flat_legacy_migrated_v1");if(has<0)return-1;if(has)return 0;if(access(s->legacy_path,F_OK)!=0)return set_meta(s->db,"flat_legacy_migrated_v1");json_object*m=json_object_from_file(s->legacy_path);if(!m)return-1;json_object*v=NULL,*a=NULL;if(!json_object_object_get_ex(m,"formatVersion",&v)||json_object_get_int(v)!=1||!json_object_object_get_ex(m,"entries",&a)||!json_object_is_type(a,json_type_array)){json_object_put(m);return-1;}if(exec_sql(s->db,"BEGIN IMMEDIATE")){json_object_put(m);return-1;}int rc=-1;sqlite3_stmt*count=NULL,*ins=NULL;if(sqlite3_prepare_v2(s->db,"SELECT COUNT(*) FROM flat_news",-1,&count,NULL)!=SQLITE_OK)goto done;int existing=sqlite3_step(count)==SQLITE_ROW?sqlite3_column_int(count,0):-1;sqlite3_finalize(count);count=NULL;if(existing<0)goto done;if(existing==0){if(sqlite3_prepare_v2(s->db,"INSERT INTO flat_news(entry) VALUES(?)",-1,&ins,NULL)!=SQLITE_OK)goto done;for(size_t i=0;i<json_object_array_length(a);i++){json_object*e=json_object_array_get_idx(a,i);uint8_t*b=NULL;size_t n=0;if(!json_object_is_type(e,json_type_string)||b64d(json_object_get_string(e),&b,&n)){free(b);goto done;}sqlite3_reset(ins);sqlite3_clear_bindings(ins);sqlite3_bind_blob(ins,1,b,(int)n,SQLITE_TRANSIENT);free(b);if(sqlite3_step(ins)!=SQLITE_DONE)goto done;}}if(set_meta(s->db,"flat_legacy_migrated_v1")||exec_sql(s->db,"COMMIT"))goto done;rc=0;
done:if(count)sqlite3_finalize(count);if(ins)sqlite3_finalize(ins);if(rc)exec_sql(s->db,"ROLLBACK");json_object_put(m);if(!rc)unlink(s->legacy_path);return rc;}
static int flat_news_count(sqlite3*db,int64_t*out){
    sqlite3_stmt*st=NULL;
    if(sqlite3_prepare_v2(db,"SELECT COUNT(*) FROM flat_news",-1,&st,NULL)!=SQLITE_OK)return-1;
    int rc=-1;
    if(sqlite3_step(st)==SQLITE_ROW){*out=sqlite3_column_int64(st,0);rc=*out>=0?0:-1;}
    sqlite3_finalize(st);
    return rc;
}
static int file_read_exact(FILE*f,void*out,size_t n){return n==0||fread(out,1,n,f)==n?0:-1;}
static int migrate_classic(cr_flat_news_store*s){
    int has=meta_exists(s->db,"flat_classic_migrated_v1");
    if(has<0)return-1;
    if(has)return 0;
    if(!s->classic_path[0]||access(s->classic_path,F_OK)!=0)return set_meta(s->db,"flat_classic_migrated_v1");
    int64_t existing=0;
    if(flat_news_count(s->db,&existing))return-1;
    if(existing>0)return set_meta(s->db,"flat_classic_migrated_v1");

    FILE*f=fopen(s->classic_path,"rb");
    if(!f)return-1;
    uint8_t raw[4];
    if(file_read_exact(f,raw,sizeof(raw))){fclose(f);return-1;}
    uint32_t count=cr_read_be32(raw);
    if(exec_sql(s->db,"BEGIN IMMEDIATE")){fclose(f);return-1;}
    sqlite3_stmt*ins=NULL;int rc=-1;
    if(sqlite3_prepare_v2(s->db,"INSERT INTO flat_news(entry) VALUES(?)",-1,&ins,NULL)!=SQLITE_OK)goto done;
    for(uint32_t i=0;i<count;i++){
        if(file_read_exact(f,raw,sizeof(raw)))goto done;
        uint32_t len=cr_read_be32(raw);
        if(!len||len>UINT16_MAX)goto done;
        uint8_t*entry=malloc(len);
        if(!entry)goto done;
        int read_failed=file_read_exact(f,entry,len);
        if(read_failed){free(entry);goto done;}
        sqlite3_reset(ins);sqlite3_clear_bindings(ins);
        sqlite3_bind_blob(ins,1,entry,(int)len,SQLITE_TRANSIENT);
        free(entry);
        if(sqlite3_step(ins)!=SQLITE_DONE)goto done;
    }
    if(fgetc(f)!=EOF||ferror(f))goto done;
    if(set_meta(s->db,"flat_classic_migrated_v1")||exec_sql(s->db,"COMMIT"))goto done;
    rc=0;
done:
    if(ins)sqlite3_finalize(ins);
    if(rc)exec_sql(s->db,"ROLLBACK");
    fclose(f);
    return rc;
}
int cr_flat_news_store_init(cr_flat_news_store*s,const char*db_path,const char*legacy_path,const char*classic_path){
    memset(s,0,sizeof(*s));
    if(!db_path||!legacy_path||!classic_path||strlen(db_path)>=sizeof(s->db_path)||strlen(legacy_path)>=sizeof(s->legacy_path)||strlen(classic_path)>=sizeof(s->classic_path))return-1;
    strcpy(s->db_path,db_path);strcpy(s->legacy_path,legacy_path);strcpy(s->classic_path,classic_path);
    if(pthread_mutex_init(&s->mutex,NULL))return-1;
    if(sqlite3_open_v2(db_path,&s->db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_FULLMUTEX,NULL)!=SQLITE_OK||ensure_schema(s->db)||migrate_legacy(s)||migrate_classic(s)){cr_flat_news_store_destroy(s);return-1;}
    return 0;
}
void cr_flat_news_store_destroy(cr_flat_news_store*s){if(!s)return;if(s->db){sqlite3_close(s->db);s->db=NULL;}pthread_mutex_destroy(&s->mutex);}
void cr_flat_news_entries_free(cr_buffer*e,size_t n){if(!e)return;for(size_t i=0;i<n;i++)cr_buffer_free(&e[i]);free(e);}
int cr_flat_news_all(cr_flat_news_store*s,cr_buffer**out,size_t*count){*out=NULL;*count=0;pthread_mutex_lock(&s->mutex);sqlite3_stmt*st=NULL;int rc=-1;if(sqlite3_prepare_v2(s->db,"SELECT entry FROM flat_news ORDER BY sequence",-1,&st,NULL)!=SQLITE_OK)goto done;size_t n=0,cap=0;cr_buffer*items=NULL;int step;while((step=sqlite3_step(st))==SQLITE_ROW){if(n==cap){size_t nc=cap?cap*2:8;cr_buffer*p=realloc(items,nc*sizeof(*p));if(!p){cr_flat_news_entries_free(items,n);goto done;}items=p;cap=nc;}cr_buffer_init(&items[n]);const uint8_t*b=sqlite3_column_blob(st,0);int bl=sqlite3_column_bytes(st,0);if(bl<=0||bl>UINT16_MAX||cr_buffer_append(&items[n],b,(size_t)bl)){cr_flat_news_entries_free(items,n+1);goto done;}n++;}if(step!=SQLITE_DONE){cr_flat_news_entries_free(items,n);goto done;}*out=items;*count=n;rc=0;done:if(st)sqlite3_finalize(st);pthread_mutex_unlock(&s->mutex);return rc;}
int cr_flat_news_append(cr_flat_news_store*s,const uint8_t*entry,size_t len,uint32_t*idx){if(!entry||!len||len>UINT16_MAX)return-1;pthread_mutex_lock(&s->mutex);int rc=-1;sqlite3_stmt*st=NULL;if(sqlite3_prepare_v2(s->db,"INSERT INTO flat_news(entry) VALUES(?)",-1,&st,NULL)!=SQLITE_OK)goto done;sqlite3_bind_blob(st,1,entry,(int)len,SQLITE_TRANSIENT);if(sqlite3_step(st)!=SQLITE_DONE){sqlite3_finalize(st);st=NULL;goto done;}sqlite3_finalize(st);st=NULL;if(sqlite3_prepare_v2(s->db,"SELECT COUNT(*) FROM flat_news",-1,&st,NULL)!=SQLITE_OK)goto done;if(sqlite3_step(st)!=SQLITE_ROW||sqlite3_column_int64(st,0)>UINT32_MAX)goto done;if(idx)*idx=(uint32_t)sqlite3_column_int64(st,0);rc=0;done:if(st)sqlite3_finalize(st);pthread_mutex_unlock(&s->mutex);return rc;}
int cr_flat_news_delete(cr_flat_news_store*s,uint32_t wi){if(!wi)return-1;pthread_mutex_lock(&s->mutex);int rc=-1;sqlite3_stmt*st=NULL;if(sqlite3_prepare_v2(s->db,"DELETE FROM flat_news WHERE sequence=(SELECT sequence FROM flat_news ORDER BY sequence LIMIT 1 OFFSET ?)",-1,&st,NULL)!=SQLITE_OK)goto done;sqlite3_bind_int64(st,1,(sqlite3_int64)(wi-1));if(sqlite3_step(st)!=SQLITE_DONE||sqlite3_changes(s->db)!=1)goto done;rc=0;done:if(st)sqlite3_finalize(st);pthread_mutex_unlock(&s->mutex);return rc;}
int cr_flat_news_clear(cr_flat_news_store*s){pthread_mutex_lock(&s->mutex);int rc=exec_sql(s->db,"DELETE FROM flat_news");pthread_mutex_unlock(&s->mutex);return rc;}
