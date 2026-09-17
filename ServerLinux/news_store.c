#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#include "news_store.h"
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <json-c/json.h>
#include <openssl/evp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>
extern time_t timegm(struct tm *);

#define CR_NEWS_LEGACY_FORMAT_VERSION 3
#define CR_NEWS_DB_SCHEMA_VERSION 2

static int exec_sql(sqlite3 *db,const char *sql){char*e=NULL;int rc=sqlite3_exec(db,sql,NULL,NULL,&e);if(rc!=SQLITE_OK){if(e)sqlite3_free(e);return-1;}return 0;}
static int ensure_schema(sqlite3 *db){
    sqlite3_busy_timeout(db,5000);
    if(exec_sql(db,"PRAGMA journal_mode=WAL;PRAGMA synchronous=NORMAL;PRAGMA foreign_keys=ON;"))return-1;
    if(exec_sql(db,
      "CREATE TABLE IF NOT EXISTS news_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);"
      "CREATE TABLE IF NOT EXISTS news_group_sequences(group_id TEXT PRIMARY KEY,next_article_id INTEGER NOT NULL);"
      "CREATE TABLE IF NOT EXISTS news_articles(group_id TEXT NOT NULL,article_id INTEGER NOT NULL,subject BLOB NOT NULL,sender BLOB NOT NULL,legacy_date INTEGER NOT NULL,created_at REAL NOT NULL,body BLOB NOT NULL,parent_article_id INTEGER NOT NULL,thread_id INTEGER NOT NULL,owner_account_id TEXT,is_deleted INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(group_id,article_id));"
      "CREATE INDEX IF NOT EXISTS news_articles_thread_idx ON news_articles(group_id,thread_id,article_id);"
      "CREATE INDEX IF NOT EXISTS news_articles_created_idx ON news_articles(group_id,created_at);"
      "CREATE TABLE IF NOT EXISTS news_reactions(group_id TEXT NOT NULL,article_id INTEGER NOT NULL,account_id TEXT NOT NULL,reaction INTEGER NOT NULL,PRIMARY KEY(group_id,article_id,account_id),FOREIGN KEY(group_id,article_id) REFERENCES news_articles(group_id,article_id) ON DELETE CASCADE);"
      "CREATE INDEX IF NOT EXISTS news_reactions_article_idx ON news_reactions(group_id,article_id,reaction);"
      "CREATE TABLE IF NOT EXISTS flat_news(sequence INTEGER PRIMARY KEY AUTOINCREMENT,entry BLOB NOT NULL);"))return-1;
    sqlite3_stmt*st=NULL;int version=-1;
    if(sqlite3_prepare_v2(db,"SELECT value FROM news_meta WHERE key='schema_version'",-1,&st,NULL)!=SQLITE_OK)return-1;
    if(sqlite3_step(st)==SQLITE_ROW)version=atoi((const char*)sqlite3_column_text(st,0));
    sqlite3_finalize(st);
    if(version==-1){
        if(exec_sql(db,"INSERT INTO news_meta(key,value) VALUES('schema_version','2')"))return-1;
    }else if(version==1){
        if(exec_sql(db,"BEGIN IMMEDIATE"))return-1;
        if(exec_sql(db,"ALTER TABLE news_articles ADD COLUMN owner_account_id TEXT;ALTER TABLE news_articles ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0;UPDATE news_meta SET value='2' WHERE key='schema_version';COMMIT")){
            (void)exec_sql(db,"ROLLBACK");return-1;
        }
    }else if(version!=CR_NEWS_DB_SCHEMA_VERSION)return-1;
    return 0;
}
static int meta_exists(sqlite3*db,const char*key){sqlite3_stmt*st=NULL;int found=0;if(sqlite3_prepare_v2(db,"SELECT 1 FROM news_meta WHERE key=?",-1,&st,NULL)!=SQLITE_OK)return-1;sqlite3_bind_text(st,1,key,-1,SQLITE_TRANSIENT);int rc=sqlite3_step(st);if(rc==SQLITE_ROW)found=1;else if(rc!=SQLITE_DONE)found=-1;sqlite3_finalize(st);return found;}
static int set_meta(sqlite3*db,const char*key){sqlite3_stmt*st=NULL;if(sqlite3_prepare_v2(db,"INSERT OR REPLACE INTO news_meta(key,value) VALUES(?,'1')",-1,&st,NULL)!=SQLITE_OK)return-1;sqlite3_bind_text(st,1,key,-1,SQLITE_TRANSIENT);int rc=sqlite3_step(st)==SQLITE_DONE?0:-1;sqlite3_finalize(st);return rc;}
static void lower_id(const char*id,char*out,size_t cap){size_t n=strlen(id);if(n+1>cap)n=cap-1;for(size_t i=0;i<n;i++)out[i]=(char)tolower((unsigned char)id[i]);out[n]=0;}
static int read_file(const char*p,cr_buffer*b){int fd=open(p,O_RDONLY);if(fd<0)return-1;struct stat st;if(fstat(fd,&st)||st.st_size<0){close(fd);return-1;}b->len=0;if(cr_buffer_reserve(b,(size_t)st.st_size)){close(fd);return-1;}while(b->len<(size_t)st.st_size){ssize_t n=read(fd,b->data+b->len,(size_t)st.st_size-b->len);if(n<0){if(errno==EINTR)continue;close(fd);return-1;}if(!n){close(fd);return-1;}b->len+=(size_t)n;}close(fd);return 0;}
static int b64d(const char*s,uint8_t**out,size_t*n){*out=NULL;*n=0;if(!s)return-1;if(!*s)return 0;size_t l=strlen(s),c=(l/4)*3+3;uint8_t*b=malloc(c);if(!b)return-1;int x=EVP_DecodeBlock(b,(const unsigned char*)s,(int)l);if(x<0){free(b);return-1;}while(l&&s[l-1]=='='){x--;l--;}*out=b;*n=(size_t)x;return 0;}
static time_t iso_time(const char*s){struct tm t={0};if(!s||!strptime(s,"%Y-%m-%dT%H:%M:%S",&t))return 0;return timegm(&t);}
static int rm_tree(const char*p){struct stat st;if(lstat(p,&st))return errno==ENOENT?0:-1;if(!S_ISDIR(st.st_mode)||S_ISLNK(st.st_mode))return unlink(p);DIR*d=opendir(p);if(!d)return-1;struct dirent*e;int rc=0;while((e=readdir(d))){if(!strcmp(e->d_name,".")||!strcmp(e->d_name,".."))continue;char c[PATH_MAX];if(snprintf(c,sizeof(c),"%s/%s",p,e->d_name)>=(int)sizeof(c)||rm_tree(c)){rc=-1;break;}}closedir(d);return rc?rc:rmdir(p);}
static uint32_t ju32(json_object*o,const char*k,uint32_t f){json_object*v=NULL;return json_object_object_get_ex(o,k,&v)?(uint32_t)json_object_get_int64(v):f;}

static int migrate_legacy(cr_news_store*s){
    int has=meta_exists(s->db,"threaded_legacy_migrated_v1");if(has<0)return-1;if(has)return 0;
    DIR*d=opendir(s->legacy_root);if(!d){if(errno!=ENOENT)return-1;return set_meta(s->db,"threaded_legacy_migrated_v1");}
    if(exec_sql(s->db,"BEGIN IMMEDIATE")){closedir(d);return-1;}int rc=-1;struct dirent*de;
    sqlite3_stmt*ins=NULL,*seq=NULL,*react=NULL;
    if(sqlite3_prepare_v2(s->db,"INSERT OR IGNORE INTO news_articles(group_id,article_id,subject,sender,legacy_date,created_at,body,parent_article_id,thread_id) VALUES(?,?,?,?,?,?,?,?,?)",-1,&ins,NULL)!=SQLITE_OK||
       sqlite3_prepare_v2(s->db,"INSERT INTO news_group_sequences(group_id,next_article_id) VALUES(?,?) ON CONFLICT(group_id) DO UPDATE SET next_article_id=excluded.next_article_id",-1,&seq,NULL)!=SQLITE_OK||
       sqlite3_prepare_v2(s->db,"INSERT OR IGNORE INTO news_reactions(group_id,article_id,account_id,reaction) VALUES(?,?,?,?)",-1,&react,NULL)!=SQLITE_OK)goto done;
    while((de=readdir(d))){if(de->d_name[0]=='.')continue;char dir[PATH_MAX],mp[PATH_MAX];if(snprintf(dir,sizeof(dir),"%s/%s",s->legacy_root,de->d_name)>=(int)sizeof(dir)||snprintf(mp,sizeof(mp),"%s/manifest.json",dir)>=(int)sizeof(mp))goto done;if(access(mp,F_OK)!=0)continue;json_object*m=json_object_from_file(mp);if(!m)goto done;json_object*v=NULL,*a=NULL;if(!json_object_object_get_ex(m,"formatVersion",&v)){json_object_put(m);goto done;}int fmt=json_object_get_int(v);if(fmt<1||fmt>CR_NEWS_LEGACY_FORMAT_VERSION||!json_object_object_get_ex(m,"entries",&a)||!json_object_is_type(a,json_type_array)){json_object_put(m);goto done;}char group[80];lower_id(de->d_name,group,sizeof(group));
        for(size_t i=0;i<json_object_array_length(a);i++){json_object*e=json_object_array_get_idx(a,i),*x=NULL;uint32_t aid=ju32(e,"articleID",0),parent=fmt==1?UINT32_MAX:ju32(e,"parentArticleID",UINT32_MAX),thread=fmt==1?aid:ju32(e,"threadID",aid);if(!aid||aid==UINT32_MAX||!thread||thread==UINT32_MAX){json_object_put(m);goto done;}uint8_t*sub=NULL,*sender=NULL;size_t sn=0,rn=0;if(!json_object_object_get_ex(e,"subject",&x)||b64d(json_object_get_string(x),&sub,&sn)||!json_object_object_get_ex(e,"sender",&x)||b64d(json_object_get_string(x),&sender,&rn)){free(sub);free(sender);json_object_put(m);goto done;}char bp[PATH_MAX];if(snprintf(bp,sizeof(bp),"%s/article-%u.bin",dir,aid)>=(int)sizeof(bp)){free(sub);free(sender);json_object_put(m);goto done;}cr_buffer body;cr_buffer_init(&body);if(read_file(bp,&body)){free(sub);free(sender);cr_buffer_free(&body);json_object_put(m);goto done;}const char*created="";if(json_object_object_get_ex(e,"createdAt",&x))created=json_object_get_string(x);time_t ct=iso_time(created);sqlite3_reset(ins);sqlite3_clear_bindings(ins);sqlite3_bind_text(ins,1,group,-1,SQLITE_TRANSIENT);sqlite3_bind_int64(ins,2,aid);sqlite3_bind_blob(ins,3,sub,(int)sn,SQLITE_TRANSIENT);sqlite3_bind_blob(ins,4,sender,(int)rn,SQLITE_TRANSIENT);sqlite3_bind_int64(ins,5,ju32(e,"date",0));sqlite3_bind_double(ins,6,(double)ct);sqlite3_bind_blob(ins,7,body.data,(int)body.len,SQLITE_TRANSIENT);sqlite3_bind_int64(ins,8,parent);sqlite3_bind_int64(ins,9,thread);free(sub);free(sender);cr_buffer_free(&body);if(sqlite3_step(ins)!=SQLITE_DONE){json_object_put(m);goto done;}json_object*r=NULL;if(json_object_object_get_ex(e,"reactions",&r)&&json_object_is_type(r,json_type_object)){json_object_object_foreach(r,key,val){int kind=json_object_get_int(val);if(kind<1||kind>6)continue;sqlite3_reset(react);sqlite3_clear_bindings(react);sqlite3_bind_text(react,1,group,-1,SQLITE_TRANSIENT);sqlite3_bind_int64(react,2,aid);sqlite3_bind_text(react,3,key,-1,SQLITE_TRANSIENT);sqlite3_bind_int(react,4,kind);if(sqlite3_step(react)!=SQLITE_DONE){json_object_put(m);goto done;}}}}
        uint32_t next=ju32(m,"nextArticleID",1);if(!next||next==UINT32_MAX)next=1;sqlite3_reset(seq);sqlite3_clear_bindings(seq);sqlite3_bind_text(seq,1,group,-1,SQLITE_TRANSIENT);sqlite3_bind_int64(seq,2,next);if(sqlite3_step(seq)!=SQLITE_DONE){json_object_put(m);goto done;}json_object_put(m);
    }
    if(set_meta(s->db,"threaded_legacy_migrated_v1")||exec_sql(s->db,"COMMIT"))goto done;
    rc=0;
done:if(ins)sqlite3_finalize(ins);if(seq)sqlite3_finalize(seq);if(react)sqlite3_finalize(react);closedir(d);if(rc)exec_sql(s->db,"ROLLBACK");else{DIR*clean=opendir(s->legacy_root);if(clean){while((de=readdir(clean))){if(de->d_name[0]=='.')continue;char p[PATH_MAX],m[PATH_MAX];if(snprintf(p,sizeof(p),"%s/%s",s->legacy_root,de->d_name)>=(int)sizeof(p)||snprintf(m,sizeof(m),"%s/manifest.json",p)>=(int)sizeof(m))continue;if(access(m,F_OK)==0)(void)rm_tree(p);}closedir(clean);rmdir(s->legacy_root);}}return rc;
}

static int article_info(sqlite3*db,const char*g,uint32_t aid,uint32_t*parent,uint32_t*thread){sqlite3_stmt*st=NULL;if(sqlite3_prepare_v2(db,"SELECT parent_article_id,thread_id FROM news_articles WHERE group_id=? AND article_id=?",-1,&st,NULL)!=SQLITE_OK)return-1;sqlite3_bind_text(st,1,g,-1,SQLITE_TRANSIENT);sqlite3_bind_int64(st,2,aid);int rc=sqlite3_step(st);if(rc==SQLITE_ROW){if(parent)*parent=(uint32_t)sqlite3_column_int64(st,0);if(thread)*thread=(uint32_t)sqlite3_column_int64(st,1);sqlite3_finalize(st);return 0;}sqlite3_finalize(st);return rc==SQLITE_DONE?1:-1;}
static int article_status(sqlite3*db,const char*g,uint32_t aid,char*owner,size_t owner_cap,int*deleted){sqlite3_stmt*st=NULL;if(owner&&owner_cap)owner[0]=0;if(deleted)*deleted=0;if(sqlite3_prepare_v2(db,"SELECT owner_account_id,is_deleted FROM news_articles WHERE group_id=? AND article_id=?",-1,&st,NULL)!=SQLITE_OK)return-1;sqlite3_bind_text(st,1,g,-1,SQLITE_TRANSIENT);sqlite3_bind_int64(st,2,aid);int rc=sqlite3_step(st);if(rc==SQLITE_ROW){if(owner&&owner_cap&&sqlite3_column_type(st,0)!=SQLITE_NULL)snprintf(owner,owner_cap,"%s",(const char*)sqlite3_column_text(st,0));if(deleted)*deleted=sqlite3_column_int(st,1)!=0;sqlite3_finalize(st);return 0;}sqlite3_finalize(st);return rc==SQLITE_DONE?1:-1;}
static int count_locked(cr_news_store*s,const char*g,uint32_t*out){sqlite3_stmt*st=NULL;if(sqlite3_prepare_v2(s->db,"SELECT COUNT(*) FROM news_articles WHERE group_id=?",-1,&st,NULL)!=SQLITE_OK)return-1;sqlite3_bind_text(st,1,g,-1,SQLITE_TRANSIENT);int rc=sqlite3_step(st);if(rc==SQLITE_ROW&&sqlite3_column_int64(st,0)<=UINT32_MAX){*out=(uint32_t)sqlite3_column_int64(st,0);rc=0;}else rc=-1;sqlite3_finalize(st);return rc;}

int cr_news_store_init(cr_news_store*s,const char*db_path,const char*legacy_root){memset(s,0,sizeof(*s));if(!db_path||!legacy_root||strlen(db_path)>=sizeof(s->db_path)||strlen(legacy_root)>=sizeof(s->legacy_root))return-1;strcpy(s->db_path,db_path);strcpy(s->legacy_root,legacy_root);if(pthread_mutex_init(&s->mutex,NULL))return-1;if(sqlite3_open_v2(db_path,&s->db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_FULLMUTEX,NULL)!=SQLITE_OK||ensure_schema(s->db)||migrate_legacy(s)){cr_news_store_destroy(s);return-1;}return 0;}
void cr_news_store_destroy(cr_news_store*s){if(!s)return;if(s->db){sqlite3_close(s->db);s->db=NULL;}pthread_mutex_destroy(&s->mutex);}
int cr_news_count(cr_news_store*s,const char*id,uint32_t*out){char g[80];lower_id(id,g,sizeof(g));pthread_mutex_lock(&s->mutex);int rc=count_locked(s,g,out);pthread_mutex_unlock(&s->mutex);return rc;}

int cr_news_post(cr_news_store*s,const char*id,const uint8_t*subject,size_t sn,const uint8_t*sender,size_t rn,uint32_t date,const uint8_t*text,size_t tn,const uint8_t*style,size_t stn,uint32_t parent,const char*owner_account_id,uint32_t*article_id){
    if(!sn||sn>UINT16_MAX||!rn||rn>UINT16_MAX||tn>0x40000||stn>0x40000||parent==0||!owner_account_id||!*owner_account_id||strlen(owner_account_id)>128)return-1;
    char g[80];
    lower_id(id,g,sizeof(g));
    pthread_mutex_lock(&s->mutex);
    int rc=-1;
    if(exec_sql(s->db,"BEGIN IMMEDIATE"))goto done;
    uint32_t next=1;
    sqlite3_stmt*st=NULL;
    if(sqlite3_prepare_v2(s->db,"SELECT next_article_id FROM news_group_sequences WHERE group_id=?",-1,&st,NULL)!=SQLITE_OK)goto rollback;
    sqlite3_bind_text(st,1,g,-1,SQLITE_TRANSIENT);
    if(sqlite3_step(st)==SQLITE_ROW)next=(uint32_t)sqlite3_column_int64(st,0);
    sqlite3_finalize(st);
    st=NULL;
    if(!next||next==UINT32_MAX)next=1;
    uint32_t start=next;
    while(article_info(s->db,g,next,NULL,NULL)==0){next=next==UINT32_MAX-1?1:next+1;if(next==start)goto rollback;}
    uint32_t thread=next;
    if(parent!=UINT32_MAX){uint32_t pp=0;if(article_info(s->db,g,parent,&pp,&thread))goto rollback;uint32_t rootparent=0;if(article_info(s->db,g,thread,&rootparent,NULL)||rootparent!=UINT32_MAX)goto rollback;}
    cr_buffer body;cr_buffer_init(&body);if(cr_buffer_append_u32(&body,next)||cr_buffer_append_u32(&body,parent)||cr_buffer_append_u32(&body,(uint32_t)tn)||cr_buffer_append_u32(&body,(uint32_t)stn)||cr_buffer_append(&body,text,tn)||cr_buffer_append(&body,style,stn)){cr_buffer_free(&body);goto rollback;}
    if(sqlite3_prepare_v2(s->db,"INSERT INTO news_articles(group_id,article_id,subject,sender,legacy_date,created_at,body,parent_article_id,thread_id,owner_account_id,is_deleted) VALUES(?,?,?,?,?,?,?,?,?,?,0)",-1,&st,NULL)!=SQLITE_OK){cr_buffer_free(&body);goto rollback;}sqlite3_bind_text(st,1,g,-1,SQLITE_TRANSIENT);sqlite3_bind_int64(st,2,next);sqlite3_bind_blob(st,3,subject,(int)sn,SQLITE_TRANSIENT);sqlite3_bind_blob(st,4,sender,(int)rn,SQLITE_TRANSIENT);sqlite3_bind_int64(st,5,date);sqlite3_bind_double(st,6,(double)time(NULL));sqlite3_bind_blob(st,7,body.data,(int)body.len,SQLITE_TRANSIENT);sqlite3_bind_int64(st,8,parent);sqlite3_bind_int64(st,9,thread);sqlite3_bind_text(st,10,owner_account_id,-1,SQLITE_TRANSIENT);cr_buffer_free(&body);if(sqlite3_step(st)!=SQLITE_DONE){sqlite3_finalize(st);st=NULL;goto rollback;}sqlite3_finalize(st);st=NULL;
    if(sqlite3_prepare_v2(s->db,"INSERT INTO news_group_sequences(group_id,next_article_id) VALUES(?,?) ON CONFLICT(group_id) DO UPDATE SET next_article_id=excluded.next_article_id",-1,&st,NULL)!=SQLITE_OK)goto rollback;
    sqlite3_bind_text(st,1,g,-1,SQLITE_TRANSIENT);
    sqlite3_bind_int64(st,2,next==UINT32_MAX-1?1:next+1);
    if(sqlite3_step(st)!=SQLITE_DONE){sqlite3_finalize(st);st=NULL;goto rollback;}
    sqlite3_finalize(st);
    st=NULL;
    if(exec_sql(s->db,"COMMIT"))goto rollback;
    if(article_id)*article_id=next;
    rc=0;
    goto done;
rollback:if(st)sqlite3_finalize(st);exec_sql(s->db,"ROLLBACK");
done:pthread_mutex_unlock(&s->mutex);return rc;
}

int cr_news_update_owned(cr_news_store*s,const char*id,uint32_t aid,const char*requester_account_id,int can_moderate,const uint8_t*subject,size_t sn,const uint8_t*text,size_t tn,const uint8_t*style,size_t stn){
    if(!aid||aid==UINT32_MAX||!requester_account_id||!*requester_account_id||strlen(requester_account_id)>128||!sn||sn>UINT16_MAX||tn>0x40000||stn>0x40000)return-1;
    char g[80],owner[129];lower_id(id,g,sizeof(g));pthread_mutex_lock(&s->mutex);int rc=-1,deleted=0;uint32_t parent=0;
    if(article_info(s->db,g,aid,&parent,NULL)||article_status(s->db,g,aid,owner,sizeof(owner),&deleted)||deleted||(!can_moderate&&strcasecmp(owner,requester_account_id)))goto done;
    cr_buffer body;cr_buffer_init(&body);if(cr_buffer_append_u32(&body,aid)||cr_buffer_append_u32(&body,parent)||cr_buffer_append_u32(&body,(uint32_t)tn)||cr_buffer_append_u32(&body,(uint32_t)stn)||cr_buffer_append(&body,text,tn)||cr_buffer_append(&body,style,stn)){cr_buffer_free(&body);goto done;}
    sqlite3_stmt*st=NULL;if(sqlite3_prepare_v2(s->db,"UPDATE news_articles SET subject=?,body=? WHERE group_id=? AND article_id=? AND is_deleted=0",-1,&st,NULL)!=SQLITE_OK){cr_buffer_free(&body);goto done;}sqlite3_bind_blob(st,1,subject,(int)sn,SQLITE_TRANSIENT);sqlite3_bind_blob(st,2,body.data,(int)body.len,SQLITE_TRANSIENT);sqlite3_bind_text(st,3,g,-1,SQLITE_TRANSIENT);sqlite3_bind_int64(st,4,aid);rc=sqlite3_step(st)==SQLITE_DONE&&sqlite3_changes(s->db)==1?0:-1;sqlite3_finalize(st);cr_buffer_free(&body);
done:pthread_mutex_unlock(&s->mutex);return rc;
}

int cr_news_index(cr_news_store*s,const char*id,const uint8_t*group,size_t gl,cr_buffer*out){char g[80];lower_id(id,g,sizeof(g));pthread_mutex_lock(&s->mutex);uint32_t count=0;int rc=-1;if(count_locked(s,g,&count))goto done;out->len=0;if(cr_buffer_append_string16(out,group,gl)||cr_buffer_append_u32(out,count))goto done;sqlite3_stmt*st=NULL;if(sqlite3_prepare_v2(s->db,"SELECT article_id,subject,sender,legacy_date,length(body) FROM news_articles WHERE group_id=? ORDER BY article_id",-1,&st,NULL)!=SQLITE_OK)goto done;sqlite3_bind_text(st,1,g,-1,SQLITE_TRANSIENT);while(sqlite3_step(st)==SQLITE_ROW){const uint8_t*sub=sqlite3_column_blob(st,1),*sender=sqlite3_column_blob(st,2);int sn=sqlite3_column_bytes(st,1),rn=sqlite3_column_bytes(st,2);if(cr_buffer_append_u32(out,(uint32_t)sqlite3_column_int64(st,0))||cr_buffer_append_string16(out,sub,(size_t)sn)||cr_buffer_append_string16(out,sender,(size_t)rn)||cr_buffer_append_u32(out,(uint32_t)sqlite3_column_int64(st,3))||cr_buffer_append_u32(out,(uint32_t)sqlite3_column_int64(st,4))){sqlite3_finalize(st);goto done;}}sqlite3_finalize(st);rc=0;done:pthread_mutex_unlock(&s->mutex);return rc;}

int cr_news_threads(cr_news_store*s,const char*id,cr_buffer*out){char g[80];lower_id(id,g,sizeof(g));pthread_mutex_lock(&s->mutex);int rc=-1;sqlite3_stmt*st=NULL;const char*sql="SELECT r.article_id,r.subject,r.sender,r.legacy_date,(SELECT COUNT(*)-1 FROM news_articles m WHERE m.group_id=r.group_id AND m.thread_id=r.article_id),(SELECT MAX(m.legacy_date) FROM news_articles m WHERE m.group_id=r.group_id AND m.thread_id=r.article_id) FROM news_articles r WHERE r.group_id=? AND r.parent_article_id=? ORDER BY 6 DESC,r.article_id DESC";if(sqlite3_prepare_v2(s->db,sql,-1,&st,NULL)!=SQLITE_OK)goto done;sqlite3_bind_text(st,1,g,-1,SQLITE_TRANSIENT);sqlite3_bind_int64(st,2,UINT32_MAX);cr_buffer rows;cr_buffer_init(&rows);uint32_t count=0;while(sqlite3_step(st)==SQLITE_ROW){const uint8_t*sub=sqlite3_column_blob(st,1),*sender=sqlite3_column_blob(st,2);int sn=sqlite3_column_bytes(st,1),rn=sqlite3_column_bytes(st,2);if(cr_buffer_append_u32(&rows,(uint32_t)sqlite3_column_int64(st,0))||cr_buffer_append_string16(&rows,sub,(size_t)sn)||cr_buffer_append_string16(&rows,sender,(size_t)rn)||cr_buffer_append_u32(&rows,(uint32_t)sqlite3_column_int64(st,3))||cr_buffer_append_u32(&rows,(uint32_t)sqlite3_column_int64(st,4))||cr_buffer_append_u32(&rows,(uint32_t)sqlite3_column_int64(st,5))){cr_buffer_free(&rows);sqlite3_finalize(st);goto done;}count++;}sqlite3_finalize(st);out->len=0;if(cr_buffer_append_u32(out,count)||cr_buffer_append(out,rows.data,rows.len)){cr_buffer_free(&rows);goto done;}cr_buffer_free(&rows);rc=0;done:pthread_mutex_unlock(&s->mutex);return rc;}

int cr_news_thread_posts(cr_news_store*s,const char*id,uint32_t tid,cr_buffer*out){char g[80];lower_id(id,g,sizeof(g));pthread_mutex_lock(&s->mutex);int rc=-1;uint32_t parent=0;if(article_info(s->db,g,tid,&parent,NULL)||parent!=UINT32_MAX)goto done;sqlite3_stmt*st=NULL;if(sqlite3_prepare_v2(s->db,"SELECT article_id,parent_article_id,sender,legacy_date,length(body) FROM news_articles WHERE group_id=? AND thread_id=? ORDER BY article_id",-1,&st,NULL)!=SQLITE_OK)goto done;sqlite3_bind_text(st,1,g,-1,SQLITE_TRANSIENT);sqlite3_bind_int64(st,2,tid);cr_buffer rows;cr_buffer_init(&rows);uint32_t count=0;while(sqlite3_step(st)==SQLITE_ROW){const uint8_t*sender=sqlite3_column_blob(st,2);int rn=sqlite3_column_bytes(st,2);if(cr_buffer_append_u32(&rows,(uint32_t)sqlite3_column_int64(st,0))||cr_buffer_append_u32(&rows,(uint32_t)sqlite3_column_int64(st,1))||cr_buffer_append_string16(&rows,sender,(size_t)rn)||cr_buffer_append_u32(&rows,(uint32_t)sqlite3_column_int64(st,3))||cr_buffer_append_u32(&rows,(uint32_t)sqlite3_column_int64(st,4))){cr_buffer_free(&rows);sqlite3_finalize(st);goto done;}count++;}sqlite3_finalize(st);out->len=0;if(cr_buffer_append_u32(out,count)||cr_buffer_append(out,rows.data,rows.len)){cr_buffer_free(&rows);goto done;}cr_buffer_free(&rows);rc=0;done:pthread_mutex_unlock(&s->mutex);return rc;}

int cr_news_thread_capabilities(cr_news_store*s,const char*id,uint32_t tid,const char*account_id,int can_moderate,cr_buffer*out){
    if(!account_id||!*account_id)return-1;
    char g[80];
    lower_id(id,g,sizeof(g));
    pthread_mutex_lock(&s->mutex);
    int rc=-1;
    uint32_t parent=0;
    if(article_info(s->db,g,tid,&parent,NULL)||parent!=UINT32_MAX)goto done;
    sqlite3_stmt*st=NULL;if(sqlite3_prepare_v2(s->db,"SELECT article_id,owner_account_id,is_deleted FROM news_articles WHERE group_id=? AND thread_id=? ORDER BY article_id",-1,&st,NULL)!=SQLITE_OK)goto done;sqlite3_bind_text(st,1,g,-1,SQLITE_TRANSIENT);sqlite3_bind_int64(st,2,tid);cr_buffer rows;cr_buffer_init(&rows);uint32_t count=0;int step;
    while((step=sqlite3_step(st))==SQLITE_ROW){uint32_t aid=(uint32_t)sqlite3_column_int64(st,0);const char*owner=sqlite3_column_type(st,1)==SQLITE_NULL?NULL:(const char*)sqlite3_column_text(st,1);int deleted=sqlite3_column_int(st,2)!=0;int mine=owner&&!*owner?0:(owner&&strcasecmp(owner,account_id)==0);uint8_t flags=0;if((mine||can_moderate)&&!deleted)flags|=1;if((mine||can_moderate)&&!deleted)flags|=2;if(deleted)flags|=4;if(cr_buffer_append_u32(&rows,aid)||cr_buffer_append_u8(&rows,flags)){cr_buffer_free(&rows);sqlite3_finalize(st);goto done;}count++;}
    sqlite3_finalize(st);if(step!=SQLITE_DONE){cr_buffer_free(&rows);goto done;}out->len=0;if(cr_buffer_append_u32(out,count)||cr_buffer_append(out,rows.data,rows.len)){cr_buffer_free(&rows);goto done;}cr_buffer_free(&rows);rc=0;
done:pthread_mutex_unlock(&s->mutex);return rc;
}


static int encode_reactions_locked(cr_news_store*s,const char*g,uint32_t aid,const char*account,cr_buffer*out){sqlite3_stmt*st=NULL;if(sqlite3_prepare_v2(s->db,"SELECT account_id,reaction FROM news_reactions WHERE group_id=? AND article_id=?",-1,&st,NULL)!=SQLITE_OK)return-1;sqlite3_bind_text(st,1,g,-1,SQLITE_TRANSIENT);sqlite3_bind_int64(st,2,aid);uint32_t counts[7]={0};uint8_t mine=0;int step;while((step=sqlite3_step(st))==SQLITE_ROW){int kind=sqlite3_column_int(st,1);if(kind<1||kind>6){sqlite3_finalize(st);return-1;}if(counts[kind]!=UINT32_MAX)counts[kind]++;const char*a=(const char*)sqlite3_column_text(st,0);if(account&&a&&!strcmp(a,account))mine=(uint8_t)kind;}sqlite3_finalize(st);if(step!=SQLITE_DONE)return-1;uint8_t n=0;for(int k=1;k<=6;k++)if(counts[k])n++;out->len=0;if(cr_buffer_append_u8(out,n))return-1;for(int k=1;k<=6;k++)if(counts[k]&&(cr_buffer_append_u8(out,(uint8_t)k)||cr_buffer_append_u32(out,counts[k])||cr_buffer_append_u8(out,mine==(uint8_t)k)))return-1;return 0;}
int cr_news_reactions(cr_news_store*s,const char*id,uint32_t aid,const char*account,cr_buffer*out){if(!account||!*account)return-1;char g[80];lower_id(id,g,sizeof(g));pthread_mutex_lock(&s->mutex);int deleted=0,rc=-1;if(article_status(s->db,g,aid,NULL,0,&deleted))goto done;if(deleted){out->len=0;rc=cr_buffer_append_u8(out,0)?-1:0;}else rc=encode_reactions_locked(s,g,aid,account,out);done:pthread_mutex_unlock(&s->mutex);return rc;}
int cr_news_reaction_accounts(cr_news_store*s,const char*id,uint32_t aid,cr_buffer*out){
    char g[80];lower_id(id,g,sizeof(g));pthread_mutex_lock(&s->mutex);int rc=-1,deleted=0;
    out->len=0;if(cr_buffer_append_u16(out,0))goto done;
    if(article_status(s->db,g,aid,NULL,0,&deleted)) goto done;
    if(deleted){rc=0;goto done;}
    sqlite3_stmt*st=NULL;if(sqlite3_prepare_v2(s->db,"SELECT account_id,reaction FROM news_reactions WHERE group_id=? AND article_id=? ORDER BY reaction,account_id",-1,&st,NULL)!=SQLITE_OK)goto done;
    sqlite3_bind_text(st,1,g,-1,SQLITE_TRANSIENT);sqlite3_bind_int64(st,2,aid);uint16_t count=0;int step;
    while((step=sqlite3_step(st))==SQLITE_ROW){
        const char*account=(const char*)sqlite3_column_text(st,0);int kind=sqlite3_column_int(st,1);size_t n=account?strlen(account):0;
        if(kind<1||kind>6||!n||n>UINT16_MAX||count==UINT16_MAX||cr_buffer_append_u8(out,(uint8_t)kind)||cr_buffer_append_string16(out,account,n)){sqlite3_finalize(st);goto done;}
        count++;
    }
    sqlite3_finalize(st);if(step!=SQLITE_DONE)goto done;cr_write_be16(out->data,count);rc=0;
done:pthread_mutex_unlock(&s->mutex);return rc;
}

int cr_news_set_reaction(cr_news_store*s,const char*id,uint32_t aid,const char*account,uint8_t reaction,cr_buffer*out){if(!account||!*account||strlen(account)>128||reaction>6)return-1;char g[80];lower_id(id,g,sizeof(g));pthread_mutex_lock(&s->mutex);int rc=-1,deleted=0;if(article_status(s->db,g,aid,NULL,0,&deleted)||deleted)goto done;sqlite3_stmt*st=NULL;const char*sql=reaction?"INSERT INTO news_reactions(group_id,article_id,account_id,reaction) VALUES(?,?,?,?) ON CONFLICT(group_id,article_id,account_id) DO UPDATE SET reaction=excluded.reaction":"DELETE FROM news_reactions WHERE group_id=? AND article_id=? AND account_id=?";if(sqlite3_prepare_v2(s->db,sql,-1,&st,NULL)!=SQLITE_OK)goto done;sqlite3_bind_text(st,1,g,-1,SQLITE_TRANSIENT);sqlite3_bind_int64(st,2,aid);sqlite3_bind_text(st,3,account,-1,SQLITE_TRANSIENT);if(reaction)sqlite3_bind_int(st,4,reaction);if(sqlite3_step(st)!=SQLITE_DONE){sqlite3_finalize(st);goto done;}sqlite3_finalize(st);rc=encode_reactions_locked(s,g,aid,account,out);done:pthread_mutex_unlock(&s->mutex);return rc;}

int cr_news_reply(cr_news_store*s,const char*id,const uint8_t*group,size_t gl,uint32_t aid,cr_buffer*meta,cr_buffer*body){char g[80];lower_id(id,g,sizeof(g));pthread_mutex_lock(&s->mutex);int rc=1;sqlite3_stmt*st=NULL;if(sqlite3_prepare_v2(s->db,"SELECT subject,sender,legacy_date,body,parent_article_id,(SELECT MAX(article_id) FROM news_articles p WHERE p.group_id=a.group_id AND p.article_id<a.article_id),(SELECT MIN(article_id) FROM news_articles n WHERE n.group_id=a.group_id AND n.article_id>a.article_id) FROM news_articles a WHERE group_id=? AND article_id=?",-1,&st,NULL)!=SQLITE_OK){rc=-1;goto done;}sqlite3_bind_text(st,1,g,-1,SQLITE_TRANSIENT);sqlite3_bind_int64(st,2,aid);int step=sqlite3_step(st);if(step==SQLITE_DONE){sqlite3_finalize(st);goto done;}if(step!=SQLITE_ROW){sqlite3_finalize(st);rc=-1;goto done;}const uint8_t*sub=sqlite3_column_blob(st,0),*sender=sqlite3_column_blob(st,1),*bd=sqlite3_column_blob(st,3);int sn=sqlite3_column_bytes(st,0),rn=sqlite3_column_bytes(st,1),bn=sqlite3_column_bytes(st,3);uint32_t date=(uint32_t)sqlite3_column_int64(st,2),parent=(uint32_t)sqlite3_column_int64(st,4),prev=sqlite3_column_type(st,5)==SQLITE_NULL?UINT32_MAX:(uint32_t)sqlite3_column_int64(st,5),next=sqlite3_column_type(st,6)==SQLITE_NULL?UINT32_MAX:(uint32_t)sqlite3_column_int64(st,6);meta->len=0;body->len=0;if(cr_buffer_append_string16(meta,group,gl)||cr_buffer_append_u32(meta,aid)||cr_buffer_append_u32(meta,prev)||cr_buffer_append_u32(meta,next)||cr_buffer_append_string16(meta,sub,(size_t)sn)||cr_buffer_append_string16(meta,sender,(size_t)rn)||cr_buffer_append_u32(meta,date)||cr_buffer_append(body,bd,(size_t)bn)){sqlite3_finalize(st);rc=-1;goto done;}if(body->len>=8)cr_write_be32(body->data+4,parent);sqlite3_finalize(st);rc=0;done:pthread_mutex_unlock(&s->mutex);return rc;}

static int delete_locked(cr_news_store*s,const char*g,uint32_t aid,int*deleted){uint32_t parent=0;if(deleted)*deleted=0;int exists=article_info(s->db,g,aid,&parent,NULL);if(exists==1)return 0;if(exists)return-1;sqlite3_stmt*st=NULL;const char*sql=parent==UINT32_MAX?"DELETE FROM news_articles WHERE group_id=? AND thread_id=?":"WITH RECURSIVE descendants(id) AS (SELECT ? UNION ALL SELECT a.article_id FROM news_articles a JOIN descendants d ON a.parent_article_id=d.id WHERE a.group_id=?) DELETE FROM news_articles WHERE group_id=? AND article_id IN (SELECT id FROM descendants)";if(sqlite3_prepare_v2(s->db,sql,-1,&st,NULL)!=SQLITE_OK)return-1;if(parent==UINT32_MAX){sqlite3_bind_text(st,1,g,-1,SQLITE_TRANSIENT);sqlite3_bind_int64(st,2,aid);}else{sqlite3_bind_int64(st,1,aid);sqlite3_bind_text(st,2,g,-1,SQLITE_TRANSIENT);sqlite3_bind_text(st,3,g,-1,SQLITE_TRANSIENT);}int rc=sqlite3_step(st)==SQLITE_DONE?0:-1;if(!rc&&deleted)*deleted=1;sqlite3_finalize(st);return rc;}
int cr_news_delete(cr_news_store*s,const char*id,uint32_t aid,int*deleted){char g[80];lower_id(id,g,sizeof(g));pthread_mutex_lock(&s->mutex);int rc=delete_locked(s,g,aid,deleted);pthread_mutex_unlock(&s->mutex);return rc;}

int cr_news_soft_delete(cr_news_store*s,const char*id,uint32_t aid,const char*requester_account_id,int can_moderate,int*deleted){
    if(deleted)*deleted=0;
    if(!requester_account_id||!*requester_account_id)return-1;
    char g[80],owner[129];lower_id(id,g,sizeof(g));
    pthread_mutex_lock(&s->mutex);
    int rc=-1,is_deleted=0;uint32_t parent=0;
    sqlite3_stmt*st=NULL;
    if(article_info(s->db,g,aid,&parent,NULL)||article_status(s->db,g,aid,owner,sizeof(owner),&is_deleted))goto done;
    if(is_deleted){rc=0;goto done;}
    int mine=owner[0]&&strcasecmp(owner,requester_account_id)==0;
    if(!mine&&!can_moderate)goto done;

    static const uint8_t placeholder[]="[Post deleted]";
    cr_buffer body;cr_buffer_init(&body);
    if(cr_buffer_append_u32(&body,aid)||cr_buffer_append_u32(&body,parent)||
       cr_buffer_append_u32(&body,(uint32_t)(sizeof(placeholder)-1))||cr_buffer_append_u32(&body,0)||
       cr_buffer_append(&body,placeholder,sizeof(placeholder)-1)){
        cr_buffer_free(&body);goto done;
    }
    if(exec_sql(s->db,"BEGIN IMMEDIATE")){cr_buffer_free(&body);goto done;}
    if(sqlite3_prepare_v2(s->db,"UPDATE news_articles SET body=?,is_deleted=1 WHERE group_id=? AND article_id=? AND is_deleted=0",-1,&st,NULL)!=SQLITE_OK){
        cr_buffer_free(&body);goto rollback;
    }
    sqlite3_bind_blob(st,1,body.data,(int)body.len,SQLITE_TRANSIENT);
    sqlite3_bind_text(st,2,g,-1,SQLITE_TRANSIENT);
    sqlite3_bind_int64(st,3,aid);
    if(sqlite3_step(st)!=SQLITE_DONE||sqlite3_changes(s->db)!=1){
        sqlite3_finalize(st);st=NULL;cr_buffer_free(&body);goto rollback;
    }
    sqlite3_finalize(st);st=NULL;cr_buffer_free(&body);

    if(sqlite3_prepare_v2(s->db,"DELETE FROM news_reactions WHERE group_id=? AND article_id=?",-1,&st,NULL)!=SQLITE_OK)goto rollback;
    sqlite3_bind_text(st,1,g,-1,SQLITE_TRANSIENT);
    sqlite3_bind_int64(st,2,aid);
    if(sqlite3_step(st)!=SQLITE_DONE){sqlite3_finalize(st);st=NULL;goto rollback;}
    sqlite3_finalize(st);st=NULL;
    if(exec_sql(s->db,"COMMIT"))goto rollback;
    if(deleted)*deleted=1;
    rc=0;
    goto done;
rollback:
    if(st)sqlite3_finalize(st);
    (void)exec_sql(s->db,"ROLLBACK");
done:
    pthread_mutex_unlock(&s->mutex);
    return rc;
}

int cr_news_expire(cr_news_store*s,const char*id,uint32_t after,time_t now,uint32_t*removed){if(removed)*removed=0;if(after==UINT32_MAX)return 0;char g[80];lower_id(id,g,sizeof(g));pthread_mutex_lock(&s->mutex);uint32_t before=0,after_count=0;int rc=-1;if(count_locked(s,g,&before))goto done;sqlite3_stmt*st=NULL;if(sqlite3_prepare_v2(s->db,"SELECT article_id FROM news_articles WHERE group_id=? AND created_at<=? ORDER BY article_id",-1,&st,NULL)!=SQLITE_OK)goto done;sqlite3_bind_text(st,1,g,-1,SQLITE_TRANSIENT);sqlite3_bind_double(st,2,(double)now-(double)after);uint32_t*ids=NULL;size_t n=0,cap=0;int step;while((step=sqlite3_step(st))==SQLITE_ROW){if(n==cap){size_t nc=cap?cap*2:16;uint32_t*p=realloc(ids,nc*sizeof(*p));if(!p){free(ids);sqlite3_finalize(st);goto done;}ids=p;cap=nc;}ids[n++]=(uint32_t)sqlite3_column_int64(st,0);}sqlite3_finalize(st);if(step!=SQLITE_DONE){free(ids);goto done;}for(size_t i=0;i<n;i++){int del=0;if(delete_locked(s,g,ids[i],&del)){free(ids);goto done;}}free(ids);if(count_locked(s,g,&after_count))goto done;if(removed)*removed=before-after_count;rc=0;done:pthread_mutex_unlock(&s->mutex);return rc;}

static int group_valid(const char*g,const char*const*ids,size_t n){for(size_t i=0;i<n;i++){char low[80];lower_id(ids[i],low,sizeof(low));if(!strcmp(g,low))return 1;}return 0;}
int cr_news_prune(cr_news_store*s,const char*const*ids,size_t n){pthread_mutex_lock(&s->mutex);int rc=-1;sqlite3_stmt*st=NULL;if(sqlite3_prepare_v2(s->db,"SELECT DISTINCT group_id FROM news_articles UNION SELECT group_id FROM news_group_sequences",-1,&st,NULL)!=SQLITE_OK)goto done;char**groups=NULL;size_t count=0,cap=0;int step;while((step=sqlite3_step(st))==SQLITE_ROW){const char*g=(const char*)sqlite3_column_text(st,0);if(!g||group_valid(g,ids,n))continue;if(count==cap){size_t nc=cap?cap*2:8;char**p=realloc(groups,nc*sizeof(*p));if(!p)goto cleanup;groups=p;cap=nc;}groups[count]=strdup(g);if(!groups[count])goto cleanup;count++;}sqlite3_finalize(st);st=NULL;if(step!=SQLITE_DONE)goto cleanup;for(size_t i=0;i<count;i++){sqlite3_stmt*d=NULL;if(sqlite3_prepare_v2(s->db,"DELETE FROM news_articles WHERE group_id=?",-1,&d,NULL)!=SQLITE_OK)goto cleanup;sqlite3_bind_text(d,1,groups[i],-1,SQLITE_TRANSIENT);if(sqlite3_step(d)!=SQLITE_DONE){sqlite3_finalize(d);goto cleanup;}sqlite3_finalize(d);if(sqlite3_prepare_v2(s->db,"DELETE FROM news_group_sequences WHERE group_id=?",-1,&d,NULL)!=SQLITE_OK)goto cleanup;sqlite3_bind_text(d,1,groups[i],-1,SQLITE_TRANSIENT);if(sqlite3_step(d)!=SQLITE_DONE){sqlite3_finalize(d);goto cleanup;}sqlite3_finalize(d);}rc=0;
cleanup:if(st)sqlite3_finalize(st);for(size_t i=0;i<count;i++)free(groups[i]);free(groups);done:pthread_mutex_unlock(&s->mutex);return rc;}
