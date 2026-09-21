#define _XOPEN_SOURCE 700
#define _POSIX_C_SOURCE 200809L
#include "server_state.h"
#include "sqlite_state.h"
#include "classic_banner_png.h"

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <iconv.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#if defined(__APPLE__) || defined(__linux__)
extern time_t timegm(struct tm *);
#endif

static void copy_json_string(json_object *obj, const char *key, char *out, size_t cap, const char *fallback) {
    json_object *v = NULL; const char *s = fallback ? fallback : "";
    if (obj && json_object_object_get_ex(obj,key,&v) && json_object_is_type(v,json_type_string)) s=json_object_get_string(v);
    if (!s) s = "";
    snprintf(out, cap, "%s", s);
}
static int json_bool_default(json_object *obj,const char*key,int fallback){json_object*v=NULL;return obj&&json_object_object_get_ex(obj,key,&v)?json_object_get_boolean(v):fallback;}
static int64_t json_int_default(json_object *obj,const char*key,int64_t fallback){json_object*v=NULL;return obj&&json_object_object_get_ex(obj,key,&v)?json_object_get_int64(v):fallback;}

void cr_now_iso8601(char out[64]) {
    time_t now=time(NULL); struct tm tmv; gmtime_r(&now,&tmv); strftime(out,64,"%Y-%m-%dT%H:%M:%SZ",&tmv);
}
uint32_t cr_iso8601_to_mac_timestamp(const char *text) {
    if (!text || !*text) return 0;
    struct tm tmv;
    memset(&tmv, 0, sizeof(tmv));
    const char *end = strptime(text, "%Y-%m-%dT%H:%M:%S", &tmv);
    if (!end) return 0;
#if defined(__APPLE__) || defined(__linux__)
    time_t t=timegm(&tmv);
#else
    time_t t=mktime(&tmv);
#endif
    if (t < 0) return 0;
    uint64_t value = (uint64_t)t + 2082844800ULL;
    return value > UINT32_MAX ? UINT32_MAX : (uint32_t)value;
}

static int convert_iconv(const char *to,const char *from,const char *input,size_t input_len,char*out,size_t out_cap,size_t*out_len){
    iconv_t cd=iconv_open(to,from);if(cd==(iconv_t)-1)return-1;char*in=(char*)input;size_t il=input_len;char*dst=out;size_t ol=out_cap;size_t r=iconv(cd,&in,&il,&dst,&ol);iconv_close(cd);if(r==(size_t)-1||il!=0)return-1;if(out_len)*out_len=out_cap-ol;return 0;
}
int cr_utf8_to_macroman(const char*utf8,uint8_t*out,size_t out_cap,size_t*out_len){if(!utf8)return-1;if(convert_iconv("MACINTOSH","UTF-8",utf8,strlen(utf8),(char*)out,out_cap,out_len)==0)return 0;size_t n=strlen(utf8);if(n>out_cap)return-1;for(size_t i=0;i<n;i++)out[i]=(uint8_t)((unsigned char)utf8[i]<128?utf8[i]:'?');if(out_len)*out_len=n;return 0;}
int cr_utf8_to_macroman_filtered(const char*utf8,uint8_t*out,size_t out_cap,size_t*out_len){
    if(!utf8||(!out&&out_cap))return-1;
    const unsigned char*p=(const unsigned char*)utf8;
    size_t remaining=strlen(utf8),used=0;
    while(remaining){
        size_t n=1;
        unsigned char c=p[0];
        if(c<0x80)n=1;
        else if((c&0xe0)==0xc0)n=2;
        else if((c&0xf0)==0xe0)n=3;
        else if((c&0xf8)==0xf0)n=4;
        else return-1;
        if(n>remaining)return-1;
        for(size_t i=1;i<n;i++)if((p[i]&0xc0)!=0x80)return-1;
        char scalar[5];
        memcpy(scalar,p,n);
        scalar[n]='\0';
        uint8_t mac[8];
        size_t mn=0;
        if(convert_iconv("MACINTOSH","UTF-8",scalar,n,(char*)mac,sizeof(mac),&mn)==0){
            if(used+mn>out_cap)return-1;
            if(mn)memcpy(out+used,mac,mn);
            used+=mn;
        }
        p+=n;
        remaining-=n;
    }
    if(out_len)*out_len=used;
    return 0;
}
int cr_macroman_to_utf8(const uint8_t*mac,size_t mac_len,char*out,size_t out_cap){size_t n=0;if(out_cap<1)return-1;if(convert_iconv("UTF-8","MACINTOSH",(const char*)mac,mac_len,out,out_cap-1,&n)!=0){if(mac_len>=out_cap)return-1;for(size_t i=0;i<mac_len;i++)out[i]=(char)(mac[i]<128?mac[i]:'?');n=mac_len;}out[n]='\0';return 0;}

static int base64_decode(const char *text,uint8_t **out,size_t *out_len){
    *out=NULL;*out_len=0;if(!text||!*text)return 0;size_t n=strlen(text),cap=(n/4)*3+3;uint8_t*b=malloc(cap);if(!b)return-1;int decoded=EVP_DecodeBlock(b,(const unsigned char*)text,(int)n);if(decoded<0){free(b);return-1;}while(n&&text[n-1]=='='){decoded--;n--;}*out=b;*out_len=(size_t)decoded;return 0;
}
static char *base64_encode(const uint8_t *data,size_t len){size_t cap=4*((len+2)/3)+1;char*out=malloc(cap);if(!out)return NULL;int n=EVP_EncodeBlock((unsigned char*)out,data,(int)len);if(n<0){free(out);return NULL;}out[n]='\0';return out;}

static void free_parsed(cr_server_state *s){for(size_t i=0;i<s->account_count;i++){free(s->accounts[i].picture);s->accounts[i].picture=NULL;s->accounts[i].picture_len=0;}free(s->identity.banner_data);s->identity.banner_data=NULL;s->identity.banner_len=0;free(s->agreement_text);s->agreement_text=NULL;s->account_group_count=0;s->account_count=0;s->newsgroup_count=0;s->ip_restriction_count=0;}

static int ensure_dir(const char *path){char tmp[PATH_MAX];size_t n=strlen(path);if(!n||n>=sizeof(tmp))return-1;memcpy(tmp,path,n+1);if(tmp[n-1]=='/')tmp[n-1]='\0';for(char*p=tmp+1;*p;p++){if(*p=='/'){*p='\0';if(mkdir(tmp,0755)&&errno!=EEXIST)return-1;*p='/';}}return mkdir(tmp,0755)==0||errno==EEXIST?0:-1;}
static int state_join_path(char *out,size_t cap,const char *base,const char *suffix){size_t a=strlen(base),b=strlen(suffix);if(a+b+1>cap)return-1;memcpy(out,base,a);memcpy(out+a,suffix,b+1);return 0;}
static int derive_support_paths(cr_server_state*s,const char*support_root){
    if(!support_root||!*support_root||strlen(support_root)>=sizeof(s->base_dir))return-1;
    strcpy(s->base_dir,support_root);
    if(state_join_path(s->storage_root,sizeof(s->storage_root),s->base_dir,"/Files")||
       state_join_path(s->personal_home_root,sizeof(s->personal_home_root),s->base_dir,"/Users/Home")||
       state_join_path(s->metadata_path,sizeof(s->metadata_path),s->base_dir,"/file-metadata.json")||
       state_join_path(s->legacy_metadata_path,sizeof(s->legacy_metadata_path),s->base_dir,"/file-metadata-legacy.json")||
       state_join_path(s->flat_news_path,sizeof(s->flat_news_path),s->base_dir,"/flat-news.json")||
       state_join_path(s->news_root,sizeof(s->news_root),s->base_dir,"/News"))return-1;
    return 0;
}
static int derive_paths(cr_server_state*s,const char*requested){
    size_t n=strlen(requested);if(!n||n>=sizeof(s->database_dir))return-1;
    memcpy(s->database_dir,requested,n+1);
    char*slash=strrchr(s->database_dir,'/');if(slash){if(slash==s->database_dir)slash[1]='\0';else*slash='\0';}else strcpy(s->database_dir,".");
    const char *ext=strrchr(requested,'.');
    if(ext&&!strcasecmp(ext,".json")){
        if(strlen(requested)>=sizeof(s->legacy_json_path)||state_join_path(s->path,sizeof(s->path),s->database_dir,"/server.db"))return-1;
        strcpy(s->legacy_json_path,requested);
    }else{
        if(strlen(requested)>=sizeof(s->path)||state_join_path(s->legacy_json_path,sizeof(s->legacy_json_path),s->database_dir,"/server-state.json"))return-1;
        strcpy(s->path,requested);
    }
    if(state_join_path(s->news_db_path,sizeof(s->news_db_path),s->database_dir,"/news.db"))return-1;
    return derive_support_paths(s,s->database_dir);
}

static json_object *make_password_verifier(const char *password){
    uint8_t salt[16],key[32];if(RAND_bytes(salt,sizeof(salt))!=1)return NULL;if(PKCS5_PBKDF2_HMAC(password,(int)strlen(password),salt,sizeof(salt),210000,EVP_sha256(),sizeof(key),key)!=1)return NULL;char*salt64=base64_encode(salt,sizeof(salt)),*key64=base64_encode(key,sizeof(key));if(!salt64||!key64){free(salt64);free(key64);return NULL;}json_object*o=json_object_new_object();json_object_object_add(o,"algorithm",json_object_new_string("pbkdf2-sha256"));json_object_object_add(o,"iterations",json_object_new_int(210000));json_object_object_add(o,"salt",json_object_new_string(salt64));json_object_object_add(o,"derivedKey",json_object_new_string(key64));free(salt64);free(key64);return o;
}
static void make_uuid(char out[64]){uint8_t b[16];RAND_bytes(b,16);b[6]=(uint8_t)((b[6]&0x0f)|0x40);b[8]=(uint8_t)((b[8]&0x3f)|0x80);snprintf(out,64,"%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]);}

static json_object *initial_account_group(const char *id,const char *name,uint32_t color,const char *mode,const unsigned *permissions,size_t permission_count){
    json_object *g=json_object_new_object(),*p=json_object_new_array();if(!g||!p){if(g)json_object_put(g);if(p)json_object_put(p);return NULL;}
    json_object_object_add(g,"id",json_object_new_string(id));json_object_object_add(g,"name",json_object_new_string(name));
    json_object_object_add(g,"colorRGB",json_object_new_int64(color));json_object_object_add(g,"legacyMode",json_object_new_string(mode));
    json_object_object_add(g,"filesRootPath",json_object_new_string(""));json_object_object_add(g,"filesRootName",json_object_new_string("Allgemein"));
    for(size_t i=0;i<permission_count;i++)json_object_array_add(p,json_object_new_int((int)permissions[i]));
    json_object_object_add(g,"permissions",p);
    return g;
}
static json_object *initial_account(const char *login,const char *name,const char *mode,const char *group_id,uint32_t color_rgb,const unsigned *permissions,size_t permission_count){
    json_object *a=json_object_new_object(), *p=json_object_new_array(); char uuid[64],now[64];
    if(!a||!p){if(a)json_object_put(a);if(p)json_object_put(p);return NULL;}
    make_uuid(uuid);cr_now_iso8601(now);
    json_object_object_add(a,"id",json_object_new_string(uuid));json_object_object_add(a,"login",json_object_new_string(login));json_object_object_add(a,"name",json_object_new_string(name));
    json_object_object_add(a,"legacyPassword",json_object_new_string(""));json_object_object_add(a,"passwordVerifier",make_password_verifier(""));
    json_object_object_add(a,"mode",json_object_new_string(mode));if(group_id&&*group_id)json_object_object_add(a,"groupID",json_object_new_string(group_id));json_object_object_add(a,"colorRGB",json_object_new_int64(color_rgb&0x00ffffffu));json_object_object_add(a,"personalDirectory",json_object_new_string("none"));
    for(size_t i=0;i<permission_count;i++)json_object_array_add(p,json_object_new_int((int)permissions[i]));
    json_object_object_add(a,"permissions",p);json_object_object_add(a,"acceptsOfflineMessages",json_object_new_boolean(1));json_object_object_add(a,"createdAt",json_object_new_string(now));json_object_object_add(a,"modifiedAt",json_object_new_string(now));
    return a;
}

static json_object *initial_state(void){
    json_object*root=json_object_new_object();json_object_object_add(root,"formatVersion",json_object_new_int(4));
    json_object*auth=json_object_new_object();json_object_object_add(auth,"mode",json_object_new_string("legacyCompatible"));json_object_object_add(root,"authentication",auth);
    json_object*identity=json_object_new_object();json_object_object_add(identity,"name",json_object_new_string("Carracho Server"));json_object_object_add(identity,"operatorName",json_object_new_string("unknown"));json_object_object_add(identity,"location",json_object_new_string("unknown"));json_object_object_add(identity,"description",json_object_new_string(""));json_object_object_add(identity,"bannerURL",json_object_new_string(""));
    char*default_banner=base64_encode(k_carracho_classic_banner_png,k_carracho_classic_banner_png_len);if(default_banner){json_object_object_add(identity,"bannerData",json_object_new_string(default_banner));free(default_banner);}
    json_object_object_add(root,"identity",identity);
    json_object*adv=json_object_new_object();json_object_object_add(adv,"controlPort",json_object_new_int(6700));json_object_object_add(adv,"maxConnections",json_object_new_int(100));json_object_object_add(adv,"maxConnectionsPerIP",json_object_new_int(5));json_object_object_add(adv,"maxSimultaneousFileTransfers",json_object_new_int(20));json_object_object_add(adv,"maxFileTransfersPerUser",json_object_new_int(1));json_object_object_add(adv,"maxFolderDownloadDepth",json_object_new_int(8));json_object_object_add(adv,"newsExpirationHour",json_object_new_int(0));json_object_object_add(adv,"newsExpirationMinute",json_object_new_int(0));json_object_object_add(adv,"ipRestrictions",json_object_new_array());json_object_object_add(adv,"trackers",json_object_new_array());json_object_object_add(adv,"trackerAdvertisementFlags",json_object_new_int64(0));json_object_object_add(adv,"trackerDescription",json_object_new_string(""));json_object_object_add(root,"advanced",adv);
    json_object*runtime=json_object_new_object();json_object_object_add(runtime,"filesRoot",json_object_new_string(""));json_object_object_add(runtime,"legacyFilesRoot",json_object_new_string(""));json_object_object_add(runtime,"uploadBandwidthLimitBytesPerSecond",json_object_new_int64(0));json_object_object_add(runtime,"searchIndexExclusions",json_object_new_array());json_object_object_add(runtime,"searchIndexRebuildIntervalHours",json_object_new_int(0));json_object_object_add(root,"runtime",runtime);
    json_object*agreement=json_object_new_object();json_object_object_add(agreement,"enabled",json_object_new_boolean(0));json_object_object_add(agreement,"text",json_object_new_string(""));json_object_object_add(root,"agreement",agreement);
    static const unsigned admin_permissions[]={0x0a,0x0b,0x0c,0x0d,0x0e,0x0f,0x10,0x11,0x12,0x13,0x14,0x15,0x16,0x17,0x18,0x19,0x1c,0x21,0x22,0x23,0x24,0x25,0x26,0x27,0x28,0x2a,0x2c,0x2d,0x2e,0x2f,0x30,0x31};
    static const unsigned member_permissions[]={0x0a,0x0b,0x1c,0x2f,0x31};
    static const unsigned guest_permissions[]={0x0a,0x1c,0x2f};
    const char*staff_id="00000000-0000-0000-0000-000000000001",*member_id="00000000-0000-0000-0000-000000000002",*guest_id="00000000-0000-0000-0000-000000000003";
    json_object*account_groups=json_object_new_array();
    json_object*staff=initial_account_group(staff_id,"Administrator",0xff9f0a,"administrator",admin_permissions,sizeof(admin_permissions)/sizeof(admin_permissions[0]));
    json_object*members=initial_account_group(member_id,"Account Holder",0x0a84ff,"accountHolder",member_permissions,sizeof(member_permissions)/sizeof(member_permissions[0]));
    json_object*guests=initial_account_group(guest_id,"Guest",0x8e8e93,"guest",guest_permissions,sizeof(guest_permissions)/sizeof(guest_permissions[0]));
    if(!account_groups||!staff||!members||!guests){if(account_groups)json_object_put(account_groups);if(staff)json_object_put(staff);if(members)json_object_put(members);if(guests)json_object_put(guests);json_object_put(root);return NULL;}
    json_object_array_add(account_groups,staff);json_object_array_add(account_groups,members);json_object_array_add(account_groups,guests);json_object_object_add(root,"accountGroups",account_groups);
    json_object*accounts=json_object_new_array();json_object*admin=initial_account("admin","Administrator","administrator",staff_id,0xff9f0a,admin_permissions,sizeof(admin_permissions)/sizeof(admin_permissions[0]));json_object*guest=initial_account("anonymous","Guest","guest",guest_id,0x8e8e93,guest_permissions,sizeof(guest_permissions)/sizeof(guest_permissions[0]));
    if(!accounts||!admin||!guest){if(accounts)json_object_put(accounts);if(admin)json_object_put(admin);if(guest)json_object_put(guest);json_object_put(root);return NULL;}json_object_array_add(accounts,admin);json_object_array_add(accounts,guest);json_object_object_add(root,"accounts",accounts);
    json_object_object_add(root,"newsgroups",json_object_new_array());
    json_object*stats=json_object_new_object();const char*keys[]={"hits","connectionPeak","incorrectLogins","adminsConnected","accountHoldersConnected","guestsConnected","downloadsInProgress","totalDownloads","uploadsInProgress","totalUploads","totalMessages"};for(size_t i=0;i<sizeof(keys)/sizeof(keys[0]);i++)json_object_object_add(stats,keys[i],json_object_new_int64(0));json_object_object_add(root,"statistics",stats);return root;
}

static int migrate_state_permissions_v3(json_object*root){
    json_object*v=NULL;int format=json_object_object_get_ex(root,"formatVersion",&v)?json_object_get_int(v):2;
    if(format>=3)return 0;
    json_object*accounts=NULL;if(json_object_object_get_ex(root,"accounts",&accounts)&&json_object_is_type(accounts,json_type_array)){
        for(size_t i=0;i<json_object_array_length(accounts);i++){
            json_object*a=json_object_array_get_idx(accounts,i),*modev=NULL,*perms=NULL;
            if(!json_object_object_get_ex(a,"mode",&modev)||strcmp(json_object_get_string(modev),"administrator"))continue;
            if(!json_object_object_get_ex(a,"permissions",&perms)||!json_object_is_type(perms,json_type_array))continue;
            int had_advanced=0,had_transfer=0;
            for(size_t j=0;j<json_object_array_length(perms);j++){int bit=json_object_get_int(json_object_array_get_idx(perms,j));if(bit==0x25)had_advanced=1;else if(bit==0x26)had_transfer=1;}
            if(had_advanced&&!had_transfer)json_object_array_add(perms,json_object_new_int(0x26));
        }
    }
    json_object_object_add(root,"formatVersion",json_object_new_int(3));return 1;
}
static int json_add_permission_if_missing(json_object*object,int permission){
    json_object*perms=NULL;
    if(!object)return-1;
    if(!json_object_object_get_ex(object,"permissions",&perms)||!json_object_is_type(perms,json_type_array)){
        perms=json_object_new_array();if(!perms)return-1;json_object_object_add(object,"permissions",perms);
    }
    for(size_t i=0;i<json_object_array_length(perms);i++)if(json_object_get_int(json_object_array_get_idx(perms,i))==permission)return 0;
    return json_object_array_add(perms,json_object_new_int(permission))==0?1:-1;
}
static int migrate_state_permissions_v4(json_object*root){
    json_object*v=NULL;int format=json_object_object_get_ex(root,"formatVersion",&v)?json_object_get_int(v):3;
    if(format>=4)return 0;
    int guest_can_post=0;json_object*newsgroups=NULL;
    if(json_object_object_get_ex(root,"newsgroups",&newsgroups)&&json_object_is_type(newsgroups,json_type_array)){
        for(size_t i=0;i<json_object_array_length(newsgroups)&&!guest_can_post;i++){
            json_object*g=json_object_array_get_idx(newsgroups,i),*access=NULL,*post=NULL;
            if(g&&json_object_object_get_ex(g,"access",&access)&&json_object_is_type(access,json_type_object)&&
               json_object_object_get_ex(access,"guestsPost",&post)&&json_object_get_boolean(post))guest_can_post=1;
        }
    }
    const char*collections[]={"accountGroups","accounts"};
    const char*mode_keys[]={"legacyMode","mode"};
    for(size_t c=0;c<2;c++){
        json_object*items=NULL;if(!json_object_object_get_ex(root,collections[c],&items)||!json_object_is_type(items,json_type_array))continue;
        for(size_t i=0;i<json_object_array_length(items);i++){
            json_object*item=json_object_array_get_idx(items,i),*modev=NULL;if(!item||!json_object_object_get_ex(item,mode_keys[c],&modev)||!json_object_is_type(modev,json_type_string))continue;
            const char*mode=json_object_get_string(modev);int grant=!strcmp(mode,"administrator")||!strcmp(mode,"accountHolder")||(guest_can_post&&!strcmp(mode,"guest"));
            if(grant&&json_add_permission_if_missing(item,0x31)<0)return-1;
        }
    }
    json_object_object_add(root,"formatVersion",json_object_new_int(4));return 1;
}

static uint64_t json_permission_bits(json_object *object){
    json_object *perms=NULL;uint64_t bits=0;
    if(object&&json_object_object_get_ex(object,"permissions",&perms)&&json_object_is_type(perms,json_type_array)){
        for(size_t i=0;i<json_object_array_length(perms);i++){int bit=json_object_get_int(json_object_array_get_idx(perms,i));if(bit>=0&&bit<64)bits|=1ULL<<(unsigned)bit;}
    }
    return bits;
}
static cr_account_mode json_legacy_mode(json_object *object,const char *key){
    json_object *v=NULL;const char*mode="guest";if(object&&json_object_object_get_ex(object,key,&v)&&json_object_is_type(v,json_type_string))mode=json_object_get_string(v);
    return mode&&!strcmp(mode,"administrator")?CR_MODE_ADMIN:mode&&!strcmp(mode,"accountHolder")?CR_MODE_ACCOUNT:CR_MODE_GUEST;
}
static const char *mode_json_name(cr_account_mode mode){return mode==CR_MODE_ADMIN?"administrator":mode==CR_MODE_ACCOUNT?"accountHolder":"guest";}
static uint32_t default_group_color(cr_account_mode mode){return mode==CR_MODE_ADMIN?0xff9f0a:mode==CR_MODE_ACCOUNT?0x0a84ff:0x8e8e93;}
static const char *default_group_name(cr_account_mode mode){return mode==CR_MODE_ADMIN?"Administrator":mode==CR_MODE_ACCOUNT?"Account Holder":"Guest";}
static const char *fixed_group_id(cr_account_mode mode){return mode==CR_MODE_ADMIN?"00000000-0000-0000-0000-000000000001":mode==CR_MODE_ACCOUNT?"00000000-0000-0000-0000-000000000002":"00000000-0000-0000-0000-000000000003";}
static uint64_t default_group_permission_bits(cr_account_mode mode){
    static const unsigned admin[]={0x0a,0x0b,0x0c,0x0d,0x0e,0x0f,0x10,0x11,0x12,0x13,0x14,0x15,0x16,0x17,0x18,0x19,0x1c,0x21,0x22,0x23,0x24,0x25,0x26,0x27,0x28,0x2a,0x2c,0x2d,0x2e,0x2f,0x30,0x31};
    static const unsigned member[]={0x0a,0x0b,0x1c,0x2f,0x31};
    static const unsigned guest[]={0x0a,0x1c,0x2f};
    const unsigned *list=mode==CR_MODE_ADMIN?admin:mode==CR_MODE_ACCOUNT?member:guest;
    size_t count=mode==CR_MODE_ADMIN?sizeof(admin)/sizeof(admin[0]):mode==CR_MODE_ACCOUNT?sizeof(member)/sizeof(member[0]):sizeof(guest)/sizeof(guest[0]);
    uint64_t bits=0;for(size_t i=0;i<count;i++)bits|=1ULL<<list[i];return bits;
}
static json_object *permissions_json_from_bits(uint64_t bits);
static json_object *json_group_by_id(json_object *groups,const char *id){
    if(!groups||!json_object_is_type(groups,json_type_array)||!id||!*id)return NULL;
    for(size_t i=0;i<json_object_array_length(groups);i++){json_object*g=json_object_array_get_idx(groups,i),*v=NULL;if(json_object_object_get_ex(g,"id",&v)&&json_object_is_type(v,json_type_string)&&!strcasecmp(json_object_get_string(v),id))return g;}
    return NULL;
}
static json_object *json_group_source_for_mode(json_object *groups,cr_account_mode mode){
    json_object*fixed=json_group_by_id(groups,fixed_group_id(mode));if(fixed)return fixed;
    if(!groups||!json_object_is_type(groups,json_type_array))return NULL;
    for(size_t i=0;i<json_object_array_length(groups);i++){json_object*g=json_object_array_get_idx(groups,i);if(json_legacy_mode(g,"legacyMode")==mode)return g;}
    return NULL;
}
static uint32_t json_group_color(json_object*g,cr_account_mode mode){json_object*v=NULL;if(g&&json_object_object_get_ex(g,"colorRGB",&v)&&json_object_is_type(v,json_type_int)){int64_t n=json_object_get_int64(v);if(n>=0&&n<=0x00ffffff)return(uint32_t)n;}return default_group_color(mode);}
static const char *json_string_member(json_object*o,const char*key,const char*fallback){json_object*v=NULL;if(o&&json_object_object_get_ex(o,key,&v)&&json_object_is_type(v,json_type_string)){const char*x=json_object_get_string(v);if(x)return x;}return fallback;}
static json_object *fixed_group_json(json_object*source,cr_account_mode mode){
    uint64_t bits=source?json_permission_bits(source):default_group_permission_bits(mode);
    json_object*g=json_object_new_object(),*p=permissions_json_from_bits(bits);if(!g||!p){if(g)json_object_put(g);if(p)json_object_put(p);return NULL;}
    const char*root_path=json_string_member(source,"filesRootPath","");const char*root_name=*root_path?json_string_member(source,"filesRootName","Allgemein"):"Allgemein";
    json_object_object_add(g,"id",json_object_new_string(fixed_group_id(mode)));json_object_object_add(g,"name",json_object_new_string(default_group_name(mode)));json_object_object_add(g,"colorRGB",json_object_new_int64(json_group_color(source,mode)));json_object_object_add(g,"legacyMode",json_object_new_string(mode_json_name(mode)));json_object_object_add(g,"permissions",p);json_object_object_add(g,"filesRootPath",json_object_new_string(root_path));json_object_object_add(g,"filesRootName",json_object_new_string(root_name));return g;
}
static int migrate_account_groups(json_object *root){
    json_object *accounts=NULL,*old_groups=NULL;
    if(!json_object_object_get_ex(root,"accounts",&accounts)||!json_object_is_type(accounts,json_type_array))return-1;
    if(!json_object_object_get_ex(root,"accountGroups",&old_groups)||!json_object_is_type(old_groups,json_type_array))old_groups=NULL;
    json_object*new_groups=json_object_new_array();if(!new_groups)return-1;
    cr_account_mode modes[3]={CR_MODE_ADMIN,CR_MODE_ACCOUNT,CR_MODE_GUEST};
    for(size_t i=0;i<3;i++){json_object*g=fixed_group_json(json_group_source_for_mode(old_groups,modes[i]),modes[i]);if(!g){json_object_put(new_groups);return-1;}json_object_array_add(new_groups,g);}
    for(size_t i=0;i<json_object_array_length(accounts);i++){
        json_object*a=json_object_array_get_idx(accounts,i),*gidv=NULL,*colorv=NULL;
        json_object*assigned=NULL;const char*old_gid=NULL;
        if(json_object_object_get_ex(a,"groupID",&gidv)&&json_object_is_type(gidv,json_type_string)){old_gid=json_object_get_string(gidv);assigned=json_group_by_id(old_groups,old_gid);}
        cr_account_mode mode=assigned?json_legacy_mode(assigned,"legacyMode"):json_legacy_mode(a,"mode");
        json_object_object_add(a,"mode",json_object_new_string(mode_json_name(mode)));
        json_object_object_add(a,"groupID",json_object_new_string(fixed_group_id(mode)));
        if(!json_object_object_get_ex(a,"colorRGB",&colorv)||!json_object_is_type(colorv,json_type_int)||json_object_get_int64(colorv)<0||json_object_get_int64(colorv)>0x00ffffff){
            json_object*source=assigned?assigned:json_group_source_for_mode(old_groups,mode);
            json_object_object_add(a,"colorRGB",json_object_new_int64(json_group_color(source,mode)));
        }
    }
    json_object_object_add(root,"accountGroups",new_groups);
    return 1;
}

int cr_state_save_locked(cr_server_state*s){return s&&s->root&&s->db?cr_sqlite_state_save(s->db,s->root):-1;}
int cr_state_save(cr_server_state*s){pthread_mutex_lock(&s->mutex);int rc=cr_state_save_locked(s);pthread_mutex_unlock(&s->mutex);return rc;}

static int json_set_string_if_changed(json_object *object, const char *key, const char *value, unsigned *changed) {
    json_object *old = NULL;
    if (json_object_object_get_ex(object, key, &old) && json_object_is_type(old, json_type_string) && !strcmp(json_object_get_string(old), value))
        return 0;
    json_object_object_add(object, key, json_object_new_string(value));
    if (changed) (*changed)++;
    return 0;
}

static int json_set_int_if_changed(json_object *object, const char *key, int64_t value, unsigned *changed) {
    json_object *old = NULL;
    if (json_object_object_get_ex(object, key, &old) && json_object_is_type(old, json_type_int) && json_object_get_int64(old) == value)
        return 0;
    json_object_object_add(object, key, json_object_new_int64(value));
    if (changed) (*changed)++;
    return 0;
}

static int json_set_trackers_if_changed(json_object *advanced, const cr_startup_persistent_settings *settings, unsigned *changed) {
    json_object *old = NULL;
    int same = json_object_object_get_ex(advanced, "trackers", &old) && json_object_is_type(old, json_type_array) &&
               json_object_array_length(old) == settings->tracker_count;
    if (same) {
        for (size_t i = 0; i < settings->tracker_count; ++i) {
            json_object *item = json_object_array_get_idx(old, i), *v = NULL;
            const cr_startup_tracker_setting *src = &settings->trackers[i];
            const char *name = NULL, *address = NULL, *reserved = NULL;
            int64_t reserved_value = 0;
            if (!item || !json_object_is_type(item, json_type_object) ||
                !json_object_object_get_ex(item, "name", &v) || !json_object_is_type(v, json_type_string)) { same = 0; break; }
            name = json_object_get_string(v);
            if (!json_object_object_get_ex(item, "address", &v) || !json_object_is_type(v, json_type_string)) { same = 0; break; }
            address = json_object_get_string(v);
            if (json_object_object_get_ex(item, "reservedString", &v) && json_object_is_type(v, json_type_string))
                reserved = json_object_get_string(v);
            else
                reserved = "";
            if (json_object_object_get_ex(item, "reservedValue", &v) && json_object_is_type(v, json_type_int))
                reserved_value = json_object_get_int64(v);
            if (strcmp(name, src->name) || strcmp(address, src->address) || strcmp(reserved, src->reserved_string) ||
                (uint32_t)reserved_value != src->reserved_value) { same = 0; break; }
        }
    }
    if (same) return 0;

    json_object *array = json_object_new_array();
    if (!array) return -1;
    for (size_t i = 0; i < settings->tracker_count; ++i) {
        const cr_startup_tracker_setting *src = &settings->trackers[i];
        json_object *item = json_object_new_object();
        if (!item) { json_object_put(array); return -1; }
        json_object_object_add(item, "name", json_object_new_string(src->name));
        json_object_object_add(item, "address", json_object_new_string(src->address));
        json_object_object_add(item, "reservedString", json_object_new_string(src->reserved_string));
        json_object_object_add(item, "reservedValue", json_object_new_int64(src->reserved_value));
        json_object_array_add(array, item);
    }
    json_object_object_add(advanced, "trackers", array);
    if (changed) (*changed)++;
    return 0;
}

static int json_set_exclusions_if_changed(json_object *object, const cr_search_index_exclusions *settings, unsigned *changed) {
    json_object *old = NULL;
    int same = json_object_object_get_ex(object, "searchIndexExclusions", &old) && json_object_is_type(old, json_type_array) &&
               json_object_array_length(old) == settings->count;
    if (same) {
        for (size_t i = 0; i < settings->count; ++i) {
            json_object *value = json_object_array_get_idx(old, i);
            if (!value || !json_object_is_type(value, json_type_string) || strcmp(json_object_get_string(value), settings->patterns[i])) { same = 0; break; }
        }
    }
    if (same) return 0;
    json_object *array = json_object_new_array();
    if (!array) return -1;
    for (size_t i = 0; i < settings->count; ++i) json_object_array_add(array, json_object_new_string(settings->patterns[i]));
    json_object_object_add(object, "searchIndexExclusions", array);
    if (changed) (*changed)++;
    return 0;
}

int cr_state_apply_authentication_mode_locked(cr_server_state *s, int legacy_compatible) {
    if (!s || !s->root) return -1;
    json_object *authentication = NULL;
    if (!json_object_object_get_ex(s->root, "authentication", &authentication) || !json_object_is_type(authentication, json_type_object)) {
        authentication = json_object_new_object();
        if (!authentication) return -1;
        json_object_object_add(s->root, "authentication", authentication);
    }
    if (!legacy_compatible) {
        json_object *accounts = NULL;
        if (json_object_object_get_ex(s->root, "accounts", &accounts) && json_object_is_type(accounts, json_type_array)) {
            for (size_t i = 0; i < json_object_array_length(accounts); ++i) {
                json_object *account = json_object_array_get_idx(accounts, i), *verifier = NULL, *legacy = NULL;
                if (!account || !json_object_is_type(account, json_type_object)) return -1;
                if (!json_object_object_get_ex(account, "passwordVerifier", &verifier) || !json_object_is_type(verifier, json_type_object)) {
                    if (!json_object_object_get_ex(account, "legacyPassword", &legacy) || !json_object_is_type(legacy, json_type_string)) return -1;
                    verifier = make_password_verifier(json_object_get_string(legacy));
                    if (!verifier) return -1;
                    json_object_object_add(account, "passwordVerifier", verifier);
                }
                json_object_object_del(account, "legacyPassword");
            }
        }
    }
    json_object_object_add(authentication, "mode", json_object_new_string(legacy_compatible ? "legacyCompatible" : "modernOnly"));
    return 0;
}

int cr_state_reconcile_startup_settings(cr_server_state *s, const cr_startup_persistent_settings *settings, unsigned *changed_count) {
    if (!s || !settings) return -1;
    unsigned changed = 0;
    pthread_mutex_lock(&s->mutex);

    json_object *authentication = NULL, *advanced = NULL, *value = NULL;
    if (!json_object_object_get_ex(s->root, "authentication", &authentication) || !json_object_is_type(authentication, json_type_object)) {
        authentication = json_object_new_object();
        json_object_object_add(s->root, "authentication", authentication);
        changed++;
    }
    const char *mode = settings->legacy_compatible ? "legacyCompatible" : "modernOnly";
    const char *old_mode = NULL;
    if (json_object_object_get_ex(authentication, "mode", &value) && json_object_is_type(value, json_type_string)) old_mode = json_object_get_string(value);
    if (!old_mode || strcmp(old_mode, mode)) {
        json_object_object_add(authentication, "mode", json_object_new_string(mode));
        changed++;
    }

    json_object *identity = NULL;
    if (!json_object_object_get_ex(s->root, "identity", &identity) || !json_object_is_type(identity, json_type_object)) {
        identity = json_object_new_object();
        json_object_object_add(s->root, "identity", identity);
        changed++;
    }
    json_set_string_if_changed(identity, "name", settings->server_name, &changed);
    json_set_string_if_changed(identity, "description", settings->description, &changed);

    if (!json_object_object_get_ex(s->root, "advanced", &advanced) || !json_object_is_type(advanced, json_type_object)) {
        advanced = json_object_new_object();
        json_object_object_add(s->root, "advanced", advanced);
        changed++;
    }
    json_set_int_if_changed(advanced, "controlPort", settings->control_port, &changed);
    json_set_int_if_changed(advanced, "maxConnections", settings->max_connections, &changed);
    json_set_int_if_changed(advanced, "maxConnectionsPerIP", settings->max_connections_per_ip, &changed);
    json_set_int_if_changed(advanced, "maxSimultaneousFileTransfers", settings->max_simultaneous_file_transfers, &changed);
    json_set_int_if_changed(advanced, "maxFileTransfersPerUser", settings->max_file_transfers_per_user, &changed);
    json_set_int_if_changed(advanced, "maxFolderDownloadDepth", settings->max_folder_download_depth, &changed);
    json_set_int_if_changed(advanced, "newsExpirationHour", settings->news_expiration_hour, &changed);
    json_set_int_if_changed(advanced, "newsExpirationMinute", settings->news_expiration_minute, &changed);
    if (settings->tracker_registration_configured) {
        json_set_int_if_changed(advanced, "trackerAdvertisementFlags", settings->tracker_advertisement_flags, &changed);
        json_set_string_if_changed(advanced, "trackerDescription", settings->tracker_description, &changed);
        if (json_set_trackers_if_changed(advanced, settings, &changed)) { pthread_mutex_unlock(&s->mutex); return -1; }
    }

    json_object *runtime = NULL;
    if (!json_object_object_get_ex(s->root, "runtime", &runtime) || !json_object_is_type(runtime, json_type_object)) {
        runtime = json_object_new_object();
        json_object_object_add(s->root, "runtime", runtime);
        changed++;
    }
    json_set_string_if_changed(runtime, "filesRoot", settings->files_root, &changed);
    json_set_string_if_changed(runtime, "legacyFilesRoot", settings->legacy_files_root, &changed);
    if (settings->upload_bandwidth_limit_bytes_per_second > INT64_MAX) { pthread_mutex_unlock(&s->mutex); return -1; }
    json_set_int_if_changed(runtime, "uploadBandwidthLimitBytesPerSecond", (int64_t)settings->upload_bandwidth_limit_bytes_per_second, &changed);
    if (json_set_exclusions_if_changed(runtime, &settings->search_index_exclusions, &changed)) { pthread_mutex_unlock(&s->mutex); return -1; }
    json_set_int_if_changed(runtime, "searchIndexRebuildIntervalHours", (int64_t)settings->search_index_rebuild_interval_hours, &changed);

    int rc = 0;
    if (changed && cr_state_save_locked(s)) rc = -1;
    if (!rc && cr_state_refresh_parsed_locked(s)) rc = -1;
    pthread_mutex_unlock(&s->mutex);
    if (!rc && changed_count) *changed_count = changed;
    return rc;
}

int cr_state_refresh_parsed_locked(cr_server_state*s){
    free_parsed(s);json_object*o=NULL,*v=NULL;
    if(json_object_object_get_ex(s->root,"authentication",&o)){json_object_object_get_ex(o,"mode",&v);s->legacy_compatible=!v||strcmp(json_object_get_string(v),"modernOnly")!=0;}else s->legacy_compatible=1;
    if(json_object_object_get_ex(s->root,"identity",&o)){copy_json_string(o,"name",s->identity.name,sizeof(s->identity.name),"Carracho Server");copy_json_string(o,"operatorName",s->identity.operator_name,sizeof(s->identity.operator_name),"unknown");copy_json_string(o,"location",s->identity.location,sizeof(s->identity.location),"unknown");copy_json_string(o,"description",s->identity.description,sizeof(s->identity.description),"");copy_json_string(o,"bannerURL",s->identity.banner_url,sizeof(s->identity.banner_url),"");if(json_object_object_get_ex(o,"bannerData",&v)&&json_object_is_type(v,json_type_string))base64_decode(json_object_get_string(v),&s->identity.banner_data,&s->identity.banner_len);}
    else{snprintf(s->identity.name,sizeof(s->identity.name),"Carracho Server");}
    memset(&s->advanced,0,sizeof(s->advanced));s->advanced.control_port=6700;s->advanced.max_connections=100;s->advanced.max_connections_per_ip=5;s->advanced.max_simultaneous_file_transfers=20;s->advanced.max_file_transfers_per_user=1;s->advanced.max_folder_download_depth=8;
    if(json_object_object_get_ex(s->root,"advanced",&o)){
#define U16(K,F,D) do{int64_t x=json_int_default(o,K,D);if(x>0&&x<=65535)s->advanced.F=(uint16_t)x;}while(0)
        U16("controlPort",control_port,6700);U16("maxConnections",max_connections,100);U16("maxConnectionsPerIP",max_connections_per_ip,5);U16("maxSimultaneousFileTransfers",max_simultaneous_file_transfers,20);U16("maxFileTransfersPerUser",max_file_transfers_per_user,1);
#undef U16
        /* maxFolderDownloadDepth deliberately accepts 0: it is the public "unlimited" value.
           The generic positive-U16 parser used to turn a persisted 0 straight back into the
           default 8 whenever the state was refreshed after an admin save. */
        { int64_t x=json_int_default(o,"maxFolderDownloadDepth",8); if(x>=0&&x<=65535)s->advanced.max_folder_download_depth=(uint16_t)x; }
        s->advanced.news_expiration_hour=(uint8_t)json_int_default(o,"newsExpirationHour",0);s->advanced.news_expiration_minute=(uint8_t)json_int_default(o,"newsExpirationMinute",0);s->advanced.tracker_advertisement_flags=(uint32_t)json_int_default(o,"trackerAdvertisementFlags",0);copy_json_string(o,"trackerDescription",s->advanced.tracker_description,sizeof(s->advanced.tracker_description),"");
        json_object *rules = NULL;
        if (json_object_object_get_ex(o, "ipRestrictions", &rules) && json_object_is_type(rules, json_type_array)) {
            size_t rn = json_object_array_length(rules);
            if (rn > CR_MAX_IP_RESTRICTIONS) rn = CR_MAX_IP_RESTRICTIONS;
            for (size_t ri = 0; ri < rn; ++ri) {
                json_object *rule = json_object_array_get_idx(rules, ri), *nv = NULL, *mv = NULL;
                if (!json_object_object_get_ex(rule, "network", &nv) || !json_object_object_get_ex(rule, "mask", &mv)) continue;
                uint8_t *nb = NULL, *mb = NULL; size_t nl = 0, ml = 0;
                if (base64_decode(json_object_get_string(nv), &nb, &nl) || base64_decode(json_object_get_string(mv), &mb, &ml) || nl != 4 || ml != 4) { free(nb); free(mb); continue; }
                cr_ip_restriction *dst = &s->ip_restrictions[s->ip_restriction_count++];
                memcpy(dst->network, nb, 4); memcpy(dst->mask, mb, 4);
                dst->deny = json_bool_default(rule, "deny", 0);
                dst->reserved = (uint8_t)json_int_default(rule, "reserved", 0);
                free(nb); free(mb);
            }
        }
    }
    s->legacy_storage_root[0] = '\0';
    if (json_object_object_get_ex(s->root, "runtime", &o) && json_object_is_type(o, json_type_object))
        copy_json_string(o, "legacyFilesRoot", s->legacy_storage_root, sizeof(s->legacy_storage_root), "");
    if(json_object_object_get_ex(s->root,"agreement",&o)){s->agreement_enabled=json_bool_default(o,"enabled",0);json_object*t=NULL;const char*txt="";if(json_object_object_get_ex(o,"text",&t)&&json_object_is_type(t,json_type_string))txt=json_object_get_string(t);s->agreement_text=strdup(txt?txt:"");}else s->agreement_text=strdup("");if(!s->agreement_text)return-1;
    json_object*arr=NULL;
    if(json_object_object_get_ex(s->root,"accountGroups",&arr)&&json_object_is_type(arr,json_type_array)){
        size_t n=json_object_array_length(arr);if(n>CR_MAX_ACCOUNT_GROUPS)n=CR_MAX_ACCOUNT_GROUPS;
        for(size_t i=0;i<n;i++){
            json_object*g=json_object_array_get_idx(arr,i);cr_account_group*dst=&s->account_groups[s->account_group_count];memset(dst,0,sizeof(*dst));
            copy_json_string(g,"id",dst->id,sizeof(dst->id),"");copy_json_string(g,"name",dst->name,sizeof(dst->name),"");dst->color_rgb=(uint32_t)json_int_default(g,"colorRGB",0x0a84ff)&0x00ffffffu;dst->mode=json_legacy_mode(g,"legacyMode");dst->permission_bits=json_permission_bits(g);copy_json_string(g,"filesRootPath",dst->files_root_path,sizeof(dst->files_root_path),"");copy_json_string(g,"filesRootName",dst->files_root_name,sizeof(dst->files_root_name),"Allgemein");if(dst->id[0]&&dst->name[0])s->account_group_count++;
        }
    }
    if(json_object_object_get_ex(s->root,"accounts",&arr)&&json_object_is_type(arr,json_type_array)){
        size_t n=json_object_array_length(arr);if(n>CR_MAX_ACCOUNTS)n=CR_MAX_ACCOUNTS;
        for(size_t i=0;i<n;i++){
            json_object*a=json_object_array_get_idx(arr,i);cr_account*dst=&s->accounts[s->account_count];memset(dst,0,sizeof(*dst));copy_json_string(a,"id",dst->id,sizeof(dst->id),"");copy_json_string(a,"login",dst->login,sizeof(dst->login),"");copy_json_string(a,"name",dst->name,sizeof(dst->name),"");copy_json_string(a,"profileName",dst->profile_name,sizeof(dst->profile_name),"");copy_json_string(a,"groupID",dst->group_id,sizeof(dst->group_id),"");
            if(json_object_object_get_ex(a,"legacyPassword",&v)&&json_object_is_type(v,json_type_string)){snprintf(dst->legacy_password,sizeof(dst->legacy_password),"%s",json_object_get_string(v));dst->has_legacy_password=1;}
            char personal[64];copy_json_string(a,"personalDirectory",personal,sizeof(personal),"none");dst->personal=!strcmp(personal,"rootDirectory")?CR_PERSONAL_ROOT:!strcmp(personal,"nestedInRoot")?CR_PERSONAL_NESTED:CR_PERSONAL_NONE;
            dst->mode=json_legacy_mode(a,"mode");uint64_t direct=json_permission_bits(a);const cr_account_group*account_group=NULL;if(dst->group_id[0]){for(size_t gi=0;gi<s->account_group_count;gi++)if(!strcasecmp(s->account_groups[gi].id,dst->group_id)){account_group=&s->account_groups[gi];dst->mode=account_group->mode;break;}}
            json_object*colorv=NULL;if(json_object_object_get_ex(a,"colorRGB",&colorv)&&json_object_is_type(colorv,json_type_int)){int64_t color=json_object_get_int64(colorv);if(color>=0&&color<=0x00ffffff){dst->color_rgb=(uint32_t)color;dst->has_color=1;}}if(!dst->has_color){dst->color_rgb=account_group?account_group->color_rgb:default_group_color(dst->mode);dst->has_color=1;}
            dst->permission_bits=direct;if(dst->mode==CR_MODE_ADMIN)dst->permission_bits|=1ULL<<0;if(dst->mode==CR_MODE_ACCOUNT)dst->permission_bits|=1ULL<<1;if(dst->personal==CR_PERSONAL_NESTED)dst->permission_bits|=1ULL<<3;if(dst->personal==CR_PERSONAL_ROOT)dst->permission_bits|=1ULL<<4;
            copy_json_string(a,"email",dst->email,sizeof(dst->email),"");copy_json_string(a,"aboutMe",dst->about,sizeof(dst->about),"");copy_json_string(a,"createdAt",dst->created_at,sizeof(dst->created_at),"");copy_json_string(a,"modifiedAt",dst->modified_at,sizeof(dst->modified_at),"");copy_json_string(a,"lastLoginAt",dst->last_login_at,sizeof(dst->last_login_at),"");dst->accepts_offline_messages=json_bool_default(a,"acceptsOfflineMessages",1);dst->local_login_only=json_bool_default(a,"localLoginOnly",0);copy_json_string(a,"lastNickname",dst->last_nickname,sizeof(dst->last_nickname),"");if(json_object_object_get_ex(a,"picture",&v)&&json_object_is_type(v,json_type_string))base64_decode(json_object_get_string(v),&dst->picture,&dst->picture_len);s->account_count++;
        }
    }
    if(json_object_object_get_ex(s->root,"newsgroups",&arr)&&json_object_is_type(arr,json_type_array)){size_t n=json_object_array_length(arr);if(n>CR_MAX_NEWSGROUPS)n=CR_MAX_NEWSGROUPS;for(size_t i=0;i<n;i++){json_object*g=json_object_array_get_idx(arr,i);cr_newsgroup*d=&s->newsgroups[s->newsgroup_count++];memset(d,0,sizeof(*d));copy_json_string(g,"id",d->id,sizeof(d->id),"");copy_json_string(g,"name",d->name,sizeof(d->name),"");d->article_count=(uint32_t)json_int_default(g,"articleCount",0);int64_t ex=json_int_default(g,"expireAfterSeconds",UINT32_MAX);d->expire_after_seconds=(uint32_t)ex;json_object*access=NULL;if(json_object_object_get_ex(g,"access",&access)){d->admin_read=json_bool_default(access,"administratorsRead",1);d->admin_post=json_bool_default(access,"administratorsPost",1);d->account_read=json_bool_default(access,"accountHoldersRead",1);d->account_post=json_bool_default(access,"accountHoldersPost",1);d->guest_read=json_bool_default(access,"guestsRead",1);d->guest_post=json_bool_default(access,"guestsPost",0);}else{d->admin_read=d->admin_post=d->account_read=d->account_post=d->guest_read=1;}}}
    return 0;
}

int cr_state_reload(cr_server_state*s){pthread_mutex_lock(&s->mutex);json_object*root=cr_sqlite_state_load(s->db);if(!root){pthread_mutex_unlock(&s->mutex);return-1;}if(s->root)json_object_put(s->root);s->root=root;int rc=cr_state_refresh_parsed_locked(s);pthread_mutex_unlock(&s->mutex);return rc;}
static int cr_state_open_internal(cr_server_state*s,const char*path,const char*support_root){
    memset(s,0,sizeof(*s));
    if(pthread_mutex_init(&s->mutex,NULL)!=0)return-1;
    if(derive_paths(s,path)){pthread_mutex_destroy(&s->mutex);return-1;}
    if(support_root&&derive_support_paths(s,support_root)){pthread_mutex_destroy(&s->mutex);return-1;}
    if(support_root&&state_join_path(s->legacy_json_path,sizeof(s->legacy_json_path),s->base_dir,"/server-state.json")){pthread_mutex_destroy(&s->mutex);return-1;}
    if(ensure_dir(s->database_dir)||ensure_dir(s->base_dir)||ensure_dir(s->personal_home_root)){pthread_mutex_destroy(&s->mutex);return-1;}
    if(cr_sqlite_state_open(&s->db,s->path)){pthread_mutex_destroy(&s->mutex);return-1;}
    int has=cr_sqlite_state_has_state(s->db);
    if(has<0){cr_state_close(s);return-1;}
    if(has){s->root=cr_sqlite_state_load(s->db);}
    else if(s->legacy_json_path[0]&&access(s->legacy_json_path,F_OK)==0){s->root=json_object_from_file(s->legacy_json_path);if(s->root&&cr_state_save_locked(s)!=0){json_object_put(s->root);s->root=NULL;}}
    else{s->root=initial_state();if(s->root&&cr_state_save_locked(s)!=0){json_object_put(s->root);s->root=NULL;}}
    int migrated=s->root?migrate_state_permissions_v3(s->root):-1;int groups_migrated=s->root?migrate_account_groups(s->root):-1;int news_perm_migrated=s->root?migrate_state_permissions_v4(s->root):-1;if(migrated<0||groups_migrated<0||news_perm_migrated<0||((migrated>0||groups_migrated>0||news_perm_migrated>0)&&cr_state_save_locked(s)!=0)){cr_state_close(s);return-1;}
    json_object *account_rows=NULL;if(!s->root||!json_object_object_get_ex(s->root,"accounts",&account_rows)||cr_sqlite_sync_account_transfer_rows(s->db,account_rows)||cr_state_refresh_parsed_locked(s)!=0){cr_state_close(s);return-1;}
    return 0;
}
int cr_state_open(cr_server_state*s,const char*path){return cr_state_open_internal(s,path,NULL);}
int cr_state_open_at_root(cr_server_state*s,const char*path,const char*support_root){return cr_state_open_internal(s,path,support_root);}
void cr_state_close(cr_server_state*s){if(!s)return;pthread_mutex_lock(&s->mutex);free_parsed(s);if(s->root){json_object_put(s->root);s->root=NULL;}if(s->db){sqlite3_close(s->db);s->db=NULL;}pthread_mutex_unlock(&s->mutex);pthread_mutex_destroy(&s->mutex);}
int cr_state_find_account(cr_server_state*s,const char*login){for(size_t i=0;i<s->account_count;i++)if(!strcasecmp(s->accounts[i].login,login))return(int)i;return-1;}
int cr_account_has_permission(const cr_account*a,unsigned bit){return a&&bit<64&&((a->permission_bits>>bit)&1ULL);}
void cr_account_permission_bytes(const cr_account*a,uint8_t out[8]){memset(out,0,8);if(!a)return;for(unsigned bit=0;bit<64;bit++)if((a->permission_bits>>bit)&1ULL)out[bit/8]|=(uint8_t)(0x80u>>(bit%8));}

static json_object *stats_obj(cr_server_state*s){json_object*stats=NULL;if(!json_object_object_get_ex(s->root,"statistics",&stats)||!json_object_is_type(stats,json_type_object)){stats=json_object_new_object();json_object_object_add(s->root,"statistics",stats);}return stats;}
static int stat_add_locked(cr_server_state*s,const char*name,int64_t delta){json_object*stats=stats_obj(s),*v=NULL;int64_t old=json_object_object_get_ex(stats,name,&v)?json_object_get_int64(v):0;int64_t next=old+delta;if(next<0)next=0;json_object_object_add(stats,name,json_object_new_int64(next));return 0;}
int cr_state_stat_add(cr_server_state*s,const char*name,int64_t delta){pthread_mutex_lock(&s->mutex);stat_add_locked(s,name,delta);int rc=cr_state_save_locked(s);pthread_mutex_unlock(&s->mutex);return rc;}
int cr_state_record_account_transfer(cr_server_state*s,const char*account_id,const char*login,int is_download,uint64_t bytes){pthread_mutex_lock(&s->mutex);int rc=cr_sqlite_record_account_transfer(s->db,account_id,login,is_download,bytes);pthread_mutex_unlock(&s->mutex);return rc;}
int cr_state_offline_message_put(cr_server_state*s,const char*recipient_account_id,const uint8_t*plaintext,size_t plaintext_len,uint64_t created_at,char out_id[37]){pthread_mutex_lock(&s->mutex);int rc=cr_sqlite_offline_message_put(s->db,recipient_account_id,plaintext,plaintext_len,created_at,out_id);pthread_mutex_unlock(&s->mutex);return rc;}
int cr_state_offline_message_count(cr_server_state*s,const char*recipient_account_id,size_t*out_count){pthread_mutex_lock(&s->mutex);int rc=cr_sqlite_offline_message_count(s->db,recipient_account_id,out_count);pthread_mutex_unlock(&s->mutex);return rc;}
int cr_state_offline_message_load(cr_server_state*s,const char*recipient_account_id,cr_offline_message_blob**out_messages,size_t*out_count){pthread_mutex_lock(&s->mutex);int rc=cr_sqlite_offline_message_load(s->db,recipient_account_id,out_messages,out_count);pthread_mutex_unlock(&s->mutex);return rc;}
void cr_state_offline_message_free(cr_offline_message_blob*messages,size_t count){cr_sqlite_offline_message_free(messages,count);}
int cr_state_offline_message_ack(cr_server_state*s,const char*recipient_account_id,const char*const*ids,size_t count){pthread_mutex_lock(&s->mutex);int rc=cr_sqlite_offline_message_ack(s->db,recipient_account_id,ids,count);pthread_mutex_unlock(&s->mutex);return rc;}
int cr_state_record_login(cr_server_state*s,size_t account_index){pthread_mutex_lock(&s->mutex);if(account_index>=s->account_count){pthread_mutex_unlock(&s->mutex);return-1;}stat_add_locked(s,"hits",1);const char*k=s->accounts[account_index].mode==CR_MODE_ADMIN?"adminsConnected":s->accounts[account_index].mode==CR_MODE_ACCOUNT?"accountHoldersConnected":"guestsConnected";stat_add_locked(s,k,1);json_object*stats=stats_obj(s),*v=NULL;int64_t current=0;const char*keys[]={"adminsConnected","accountHoldersConnected","guestsConnected"};for(int i=0;i<3;i++){if(json_object_object_get_ex(stats,keys[i],&v))current+=json_object_get_int64(v);}int64_t peak=json_object_object_get_ex(stats,"connectionPeak",&v)?json_object_get_int64(v):0;if(current>peak)json_object_object_add(stats,"connectionPeak",json_object_new_int64(current));json_object*arr=NULL;if(json_object_object_get_ex(s->root,"accounts",&arr)&&account_index<json_object_array_length(arr)){json_object*a=json_object_array_get_idx(arr,account_index);char now[64];cr_now_iso8601(now);json_object_object_add(a,"lastLoginAt",json_object_new_string(now));snprintf(s->accounts[account_index].last_login_at,sizeof(s->accounts[account_index].last_login_at),"%s",now);}int rc=cr_state_save_locked(s);pthread_mutex_unlock(&s->mutex);return rc;}
int cr_state_record_disconnect(cr_server_state*s,cr_account_mode mode){const char*k=mode==CR_MODE_ADMIN?"adminsConnected":mode==CR_MODE_ACCOUNT?"accountHoldersConnected":"guestsConnected";return cr_state_stat_add(s,k,-1);}
int cr_state_set_banner(cr_server_state *s, const uint8_t *data, size_t len, const char *url) {
    pthread_mutex_lock(&s->mutex);
    json_object *identity = NULL;
    if (!json_object_object_get_ex(s->root, "identity", &identity)) {
        identity = json_object_new_object();
        json_object_object_add(s->root, "identity", identity);
    }
    char *encoded = len ? base64_encode(data, len) : NULL;
    uint8_t *copy = len ? malloc(len) : NULL;
    if ((len && !encoded) || (len && !copy)) {
        free(encoded); free(copy); pthread_mutex_unlock(&s->mutex); return -1;
    }
    if (len) {
        memcpy(copy, data, len);
        json_object_object_add(identity, "bannerData", json_object_new_string(encoded));
    } else {
        json_object_object_del(identity, "bannerData");
    }
    json_object_object_add(identity, "bannerURL", json_object_new_string(url ? url : ""));
    int rc = cr_state_save_locked(s);
    if (rc == 0) {
        free(s->identity.banner_data);
        s->identity.banner_data = copy;
        s->identity.banner_len = len;
        copy = NULL;
        snprintf(s->identity.banner_url, sizeof(s->identity.banner_url), "%s", url ? url : "");
    }
    free(copy); free(encoded);
    pthread_mutex_unlock(&s->mutex);
    return rc;
}


int cr_state_update_profile(cr_server_state *s, const char *account_id,
                            const char *name, int set_name,
                            const char *email, int set_email,
                            const char *about, int set_about,
                            const uint8_t *picture, size_t picture_len, int set_picture) {
    pthread_mutex_lock(&s->mutex);
    json_object *arr = NULL, *record = NULL;
    size_t found = SIZE_MAX;
    if (json_object_object_get_ex(s->root, "accounts", &arr) && json_object_is_type(arr, json_type_array)) {
        for (size_t i = 0; i < json_object_array_length(arr); ++i) {
            json_object *a = json_object_array_get_idx(arr, i), *idv = NULL;
            if (json_object_object_get_ex(a, "id", &idv) && !strcmp(json_object_get_string(idv), account_id)) {
                record = a; found = i; break;
            }
        }
    }
    if (!record) { pthread_mutex_unlock(&s->mutex); return -1; }
    if (set_name) {
        if (name && *name) json_object_object_add(record, "profileName", json_object_new_string(name));
        else json_object_object_del(record, "profileName");
    }
    if (set_email) {
        if (email && *email) json_object_object_add(record, "email", json_object_new_string(email));
        else json_object_object_del(record, "email");
    }
    if (set_about) {
        if (about && *about) json_object_object_add(record, "aboutMe", json_object_new_string(about));
        else json_object_object_del(record, "aboutMe");
    }
    char now[64]; cr_now_iso8601(now);
    json_object_object_add(record, "modifiedAt", json_object_new_string(now));
    char *picture64 = NULL;
    if (set_picture) {
        if (picture_len) {
            picture64 = base64_encode(picture, picture_len);
            if (!picture64) { pthread_mutex_unlock(&s->mutex); return -1; }
            json_object_object_add(record, "picture", json_object_new_string(picture64));
        } else json_object_object_del(record, "picture");
    }
    int rc = cr_state_save_locked(s);
    if (rc == 0) {
        for (size_t i = 0; i < s->account_count; ++i) {
            cr_account *a = &s->accounts[i];
            if (strcmp(a->id, account_id)) continue;
            if (set_name) snprintf(a->profile_name, sizeof(a->profile_name), "%s", name ? name : "");
            if (set_email) snprintf(a->email, sizeof(a->email), "%s", email ? email : "");
            if (set_about) snprintf(a->about, sizeof(a->about), "%s", about ? about : "");
            snprintf(a->modified_at, sizeof(a->modified_at), "%s", now);
            if (set_picture) {
                uint8_t *copy = picture_len ? malloc(picture_len) : NULL;
                if (picture_len && !copy) { rc = -1; break; }
                if (picture_len) memcpy(copy, picture, picture_len);
                free(a->picture); a->picture = copy; a->picture_len = picture_len;
            }
            break;
        }
    }
    free(picture64);
    (void)found;
    pthread_mutex_unlock(&s->mutex);
    return rc;
}

int cr_state_set_offline_message_preference(cr_server_state *s, const char *account_id, int enabled, const char *nickname) {
    if(!s||!account_id||!*account_id)return-1;
    pthread_mutex_lock(&s->mutex);
    json_object *arr=NULL,*record=NULL;size_t parsed_index=SIZE_MAX;
    if(json_object_object_get_ex(s->root,"accounts",&arr)&&json_object_is_type(arr,json_type_array)){
        for(size_t i=0;i<json_object_array_length(arr);i++){json_object*a=json_object_array_get_idx(arr,i),*idv=NULL;if(json_object_object_get_ex(a,"id",&idv)&&json_object_is_type(idv,json_type_string)&&!strcmp(json_object_get_string(idv),account_id)){record=a;break;}}
    }
    for(size_t i=0;i<s->account_count;i++)if(!strcmp(s->accounts[i].id,account_id)){parsed_index=i;break;}
    if(!record||parsed_index==SIZE_MAX){pthread_mutex_unlock(&s->mutex);return-1;}
    json_object_object_add(record,"acceptsOfflineMessages",json_object_new_boolean(enabled?1:0));
    if(nickname&&*nickname)json_object_object_add(record,"lastNickname",json_object_new_string(nickname));
    char now[64];cr_now_iso8601(now);json_object_object_add(record,"modifiedAt",json_object_new_string(now));
    int rc=cr_state_save_locked(s);
    if(rc==0){s->accounts[parsed_index].accepts_offline_messages=enabled?1:0;if(nickname&&*nickname)snprintf(s->accounts[parsed_index].last_nickname,sizeof(s->accounts[parsed_index].last_nickname),"%s",nickname);snprintf(s->accounts[parsed_index].modified_at,sizeof(s->accounts[parsed_index].modified_at),"%s",now);}
    pthread_mutex_unlock(&s->mutex);return rc;
}

int cr_state_ipv4_allowed(cr_server_state *s, const uint8_t address[4]) {
    pthread_mutex_lock(&s->mutex);
    int allowed = 1;
    for (size_t i = 0; i < s->ip_restriction_count; ++i) {
        cr_ip_restriction *r = &s->ip_restrictions[i];
        int match = 1;
        for (int j = 0; j < 4; ++j) if ((address[j] & r->mask[j]) != (r->network[j] & r->mask[j])) { match = 0; break; }
        if (match) { allowed = !r->deny; break; }
    }
    pthread_mutex_unlock(&s->mutex);
    return allowed;
}

int cr_state_prepend_ipv4_ban(cr_server_state *s, const uint8_t address[4]) {
    pthread_mutex_lock(&s->mutex);
    json_object *advanced = NULL, *arr = NULL;
    if (!json_object_object_get_ex(s->root, "advanced", &advanced)) {
        advanced = json_object_new_object(); json_object_object_add(s->root, "advanced", advanced);
    }
    if (!json_object_object_get_ex(advanced, "ipRestrictions", &arr) || !json_object_is_type(arr, json_type_array)) {
        arr = json_object_new_array(); json_object_object_add(advanced, "ipRestrictions", arr);
    }
    const uint8_t mask[4] = {255,255,255,255};
    char *network64 = base64_encode(address, 4), *mask64 = base64_encode(mask, 4);
    if (!network64 || !mask64) { free(network64); free(mask64); pthread_mutex_unlock(&s->mutex); return -1; }
    for (size_t i = json_object_array_length(arr); i > 0; --i) {
        size_t idx = i - 1; json_object *rule = json_object_array_get_idx(arr, idx), *nv=NULL,*mv=NULL,*dv=NULL;
        if (!json_object_object_get_ex(rule,"network",&nv) || !json_object_object_get_ex(rule,"mask",&mv)) continue;
        int deny = json_object_object_get_ex(rule,"deny",&dv) ? json_object_get_boolean(dv) : 0;
        if (deny && !strcmp(json_object_get_string(nv),network64) && !strcmp(json_object_get_string(mv),mask64))
            json_object_array_del_idx(arr, idx, 1);
    }
    json_object *rule = json_object_new_object();
    json_object_object_add(rule,"network",json_object_new_string(network64));
    json_object_object_add(rule,"mask",json_object_new_string(mask64));
    json_object_object_add(rule,"deny",json_object_new_boolean(1));
    json_object_object_add(rule,"reserved",json_object_new_int(0));
    json_object_array_insert_idx(arr,0,rule);
    free(network64); free(mask64);
    int rc = cr_state_save_locked(s);
    if (rc == 0) {
        size_t dst = 1;
        for (size_t i = 0; i < s->ip_restriction_count && dst < CR_MAX_IP_RESTRICTIONS; ++i) {
            cr_ip_restriction *r = &s->ip_restrictions[i];
            if (r->deny && !memcmp(r->network,address,4) && !memcmp(r->mask,mask,4)) continue;
            s->ip_restrictions[dst++] = *r;
        }
        memcpy(s->ip_restrictions[0].network,address,4); memcpy(s->ip_restrictions[0].mask,mask,4);
        s->ip_restrictions[0].deny=1; s->ip_restrictions[0].reserved=0; s->ip_restriction_count=dst;
    }
    pthread_mutex_unlock(&s->mutex);
    return rc;
}


int cr_state_record_login_id(cr_server_state *s, const char *account_id, cr_account_mode mode) {
    pthread_mutex_lock(&s->mutex);
    stat_add_locked(s,"hits",1);
    const char *k = mode==CR_MODE_ADMIN?"adminsConnected":mode==CR_MODE_ACCOUNT?"accountHoldersConnected":"guestsConnected";
    stat_add_locked(s,k,1);
    json_object *stats=stats_obj(s), *v=NULL;
    int64_t current=0; const char *keys[]={"adminsConnected","accountHoldersConnected","guestsConnected"};
    for(int i=0;i<3;i++) if(json_object_object_get_ex(stats,keys[i],&v)) current+=json_object_get_int64(v);
    int64_t peak=json_object_object_get_ex(stats,"connectionPeak",&v)?json_object_get_int64(v):0;
    if(current>peak) json_object_object_add(stats,"connectionPeak",json_object_new_int64(current));
    json_object *arr=NULL;
    if(json_object_object_get_ex(s->root,"accounts",&arr)) {
        for(size_t i=0;i<json_object_array_length(arr);++i) {
            json_object *a=json_object_array_get_idx(arr,i), *idv=NULL;
            if(json_object_object_get_ex(a,"id",&idv) && !strcmp(json_object_get_string(idv),account_id)) {
                char now[64]; cr_now_iso8601(now); json_object_object_add(a,"lastLoginAt",json_object_new_string(now));
                for(size_t j=0;j<s->account_count;j++) if(!strcmp(s->accounts[j].id,account_id)) snprintf(s->accounts[j].last_login_at,sizeof(s->accounts[j].last_login_at),"%s",now);
                break;
            }
        }
    }
    int rc=cr_state_save_locked(s); pthread_mutex_unlock(&s->mutex); return rc;
}

static json_object *permissions_json_from_bits(uint64_t bits) {
    static const unsigned supported[] = {
        0x0a,0x0b,0x0c,0x0d,0x0e,0x0f,0x10,0x11,0x12,0x13,0x14,0x15,0x16,0x17,
        0x18,0x19,0x1c,0x21,0x22,0x23,0x24,0x25,0x26,0x27,0x28,0x2a,0x2c,0x2d,0x2e,0x2f,0x30,0x31
    };
    json_object *array = json_object_new_array();
    if (!array) return NULL;
    for (size_t i = 0; i < sizeof(supported)/sizeof(supported[0]); ++i)
        if ((bits >> supported[i]) & 1ULL)
            json_object_array_add(array, json_object_new_int((int)supported[i]));
    return array;
}

static uint64_t supported_permission_bits(uint64_t bits) {
    static const unsigned supported[] = {
        0x0a,0x0b,0x0c,0x0d,0x0e,0x0f,0x10,0x11,0x12,0x13,0x14,0x15,0x16,0x17,
        0x18,0x19,0x1c,0x21,0x22,0x23,0x24,0x25,0x26,0x27,0x28,0x2a,0x2c,0x2d,0x2e,0x2f,0x30,0x31
    };
    uint64_t result=0;
    for(size_t i=0;i<sizeof(supported)/sizeof(supported[0]);i++)
        if((bits>>supported[i])&1ULL)result|=1ULL<<supported[i];
    return result;
}


static const char *personal_string_from_bits(uint64_t bits) {
    if (bits & (1ULL << 4)) return "rootDirectory";
    if (bits & (1ULL << 3)) return "nestedInRoot";
    return "none";
}

static int json_account_index_casefold(json_object *arr, const char *login, size_t *out) {
    if (!arr || !json_object_is_type(arr,json_type_array)) return -1;
    for (size_t i=0;i<json_object_array_length(arr);++i) {
        json_object *a=json_object_array_get_idx(arr,i),*v=NULL;
        if (json_object_object_get_ex(a,"login",&v) && !strcasecmp(json_object_get_string(v),login)) {
            if(out)*out=i;
            return 0;
        }
    }
    return -1;
}
static int json_group_index_casefold(json_object *arr, const char *name, size_t *out) {
    if (!arr || !json_object_is_type(arr,json_type_array)) return -1;
    for (size_t i=0;i<json_object_array_length(arr);++i) {
        json_object *g=json_object_array_get_idx(arr,i),*v=NULL;
        if (json_object_object_get_ex(g,"name",&v) && !strcasecmp(json_object_get_string(v),name)) {
            if(out)*out=i;
            return 0;
        }
    }
    return -1;
}
static int account_json_compare(const void *lhs,const void *rhs) {
    json_object *a=*(json_object *const*)lhs,*b=*(json_object *const*)rhs,*av=NULL,*bv=NULL;
    const char *as="",*bs="";
    if(json_object_object_get_ex(a,"login",&av))as=json_object_get_string(av);
    if(json_object_object_get_ex(b,"login",&bv))bs=json_object_get_string(bv);
    return strcasecmp(as?as:"",bs?bs:"");
}
static int group_json_compare(const void *lhs,const void *rhs) {
    json_object *a=*(json_object *const*)lhs,*b=*(json_object *const*)rhs,*av=NULL,*bv=NULL;
    const char *as="",*bs="";
    if(json_object_object_get_ex(a,"name",&av))as=json_object_get_string(av);
    if(json_object_object_get_ex(b,"name",&bv))bs=json_object_get_string(bv);
    return strcasecmp(as?as:"",bs?bs:"");
}

static const cr_account_group *parsed_group_by_id(const cr_server_state *s,const char *id){
    if(!id||!*id)return NULL;
    for(size_t i=0;i<s->account_group_count;i++)if(!strcasecmp(s->account_groups[i].id,id))return&s->account_groups[i];
    return NULL;
}

int cr_state_ensure_local_bot_account(cr_server_state *s){
    if(!s)return-1;
    pthread_mutex_lock(&s->mutex);
    json_object*arr=NULL;
    if(!json_object_object_get_ex(s->root,"accounts",&arr)||!json_object_is_type(arr,json_type_array)){
        arr=json_object_new_array();if(!arr){pthread_mutex_unlock(&s->mutex);return-1;}json_object_object_add(s->root,"accounts",arr);
    }
    json_object*record=NULL;
    for(size_t i=0;i<json_object_array_length(arr);i++){
        json_object*a=json_object_array_get_idx(arr,i),*idv=NULL;
        if(json_object_object_get_ex(a,"id",&idv)&&json_object_is_type(idv,json_type_string)&&!strcasecmp(json_object_get_string(idv),CR_LOCAL_BOT_ACCOUNT_ID)){record=a;break;}
    }
    char now[64];cr_now_iso8601(now);
    if(record){
        json_object_object_add(record,"localLoginOnly",json_object_new_boolean(1));
        json_object_object_add(record,"acceptsOfflineMessages",json_object_new_boolean(0));
        json_object_object_del(record,"legacyPassword");
        json_object*verifier=NULL;
        if(!json_object_object_get_ex(record,"passwordVerifier",&verifier)||!json_object_is_type(verifier,json_type_object)){
            char a[64],b[64],secret[160];make_uuid(a);make_uuid(b);snprintf(secret,sizeof(secret),"%s%s",a,b);
            verifier=make_password_verifier(secret);OPENSSL_cleanse(secret,sizeof(secret));
            if(!verifier){pthread_mutex_unlock(&s->mutex);return-1;}
            json_object_object_add(record,"passwordVerifier",verifier);
        }
        int rc=cr_state_save_locked(s);if(rc==0)rc=cr_state_refresh_parsed_locked(s);pthread_mutex_unlock(&s->mutex);return rc;
    }
    const cr_account_group*group=parsed_group_by_id(s,fixed_group_id(CR_MODE_ACCOUNT));
    if(!group){pthread_mutex_unlock(&s->mutex);return-1;}
    char login[256]="bot";unsigned suffix=2;size_t conflict=0;
    while(json_account_index_casefold(arr,login,&conflict)==0){if(snprintf(login,sizeof(login),"bot-%u",suffix++)>=(int)sizeof(login)){pthread_mutex_unlock(&s->mutex);return-1;}}
    json_object*perms=permissions_json_from_bits(1ULL<<0x1c);record=json_object_new_object();
    char u1[64],u2[64],secret[160];make_uuid(u1);make_uuid(u2);snprintf(secret,sizeof(secret),"%s%s",u1,u2);json_object*verifier=make_password_verifier(secret);OPENSSL_cleanse(secret,sizeof(secret));
    if(!record||!perms||!verifier){if(record)json_object_put(record);if(perms)json_object_put(perms);if(verifier)json_object_put(verifier);pthread_mutex_unlock(&s->mutex);return-1;}
    json_object_object_add(record,"id",json_object_new_string(CR_LOCAL_BOT_ACCOUNT_ID));json_object_object_add(record,"login",json_object_new_string(login));json_object_object_add(record,"name",json_object_new_string("Bot"));
    json_object_object_add(record,"passwordVerifier",verifier);json_object_object_add(record,"mode",json_object_new_string("accountHolder"));json_object_object_add(record,"groupID",json_object_new_string(group->id));
    json_object_object_add(record,"colorRGB",json_object_new_int64(group->color_rgb));json_object_object_add(record,"personalDirectory",json_object_new_string("none"));json_object_object_add(record,"permissions",perms);
    json_object_object_add(record,"permissionsOverrideGroupDefaults",json_object_new_boolean(1));json_object_object_add(record,"colorOverridesGroupDefault",json_object_new_boolean(1));
    json_object_object_add(record,"localLoginOnly",json_object_new_boolean(1));json_object_object_add(record,"acceptsOfflineMessages",json_object_new_boolean(0));json_object_object_add(record,"lastNickname",json_object_new_string("Bot"));
    json_object_object_add(record,"createdAt",json_object_new_string(now));json_object_object_add(record,"modifiedAt",json_object_new_string(now));json_object_array_add(arr,record);json_object_array_sort(arr,account_json_compare);
    int rc=cr_state_save_locked(s);if(rc==0)rc=cr_state_refresh_parsed_locked(s);pthread_mutex_unlock(&s->mutex);return rc;
}

int cr_state_account_upsert(cr_server_state *s, const char *old_login, const char *login,
                            const char *name, const char *password, uint64_t permission_bits,
                            const char *group_id, int has_color, uint32_t color_rgb, int *action_out) {
    if (!login || !*login || strlen(login)>255 || !name || strlen(name)>511 || !password || strlen(password)>511 ||
        (group_id&&strlen(group_id)>63) || (has_color&&color_rgb>0x00ffffffu)) return -1;
    pthread_mutex_lock(&s->mutex);
    cr_account_mode inferred_mode=(permission_bits&1ULL)?CR_MODE_ADMIN:(permission_bits&(1ULL<<1))?CR_MODE_ACCOUNT:CR_MODE_GUEST;
    const cr_account_group *group=(group_id&&*group_id)?parsed_group_by_id(s,group_id):parsed_group_by_id(s,fixed_group_id(inferred_mode));
    if(!group || strcasecmp(group->id,fixed_group_id(group->mode))){pthread_mutex_unlock(&s->mutex);return-1;}
    json_object *arr=NULL;
    if(!json_object_object_get_ex(s->root,"accounts",&arr)||!json_object_is_type(arr,json_type_array)){
        arr=json_object_new_array();json_object_object_add(s->root,"accounts",arr);
    }
    size_t existing=SIZE_MAX, conflict=SIZE_MAX;
    int modifying=old_login&&*old_login;
    if(modifying && json_account_index_casefold(arr,old_login,&existing)!=0){pthread_mutex_unlock(&s->mutex);return-1;}
    if(json_account_index_casefold(arr,login,&conflict)==0 && (!modifying||conflict!=existing)){pthread_mutex_unlock(&s->mutex);return-1;}
    json_object *record=NULL;
    char now[64];cr_now_iso8601(now);
    if(modifying){record=json_object_array_get_idx(arr,existing);}
    else{
        record=json_object_new_object();if(!record){pthread_mutex_unlock(&s->mutex);return-1;}
        char uuid[64];make_uuid(uuid);json_object_object_add(record,"id",json_object_new_string(uuid));
        json_object_object_add(record,"createdAt",json_object_new_string(now));
    }
    cr_account_mode effective_mode=group->mode;
    json_object *perms=permissions_json_from_bits(permission_bits);
    int local_only=modifying&&json_bool_default(record,"localLoginOnly",0);
    int preserve_password=local_only||(modifying&&!s->legacy_compatible&&password[0]=='\0');
    json_object *verifier=preserve_password?NULL:make_password_verifier(password);
    if(!perms||(!preserve_password&&!verifier)){if(perms)json_object_put(perms);if(verifier)json_object_put(verifier);if(!modifying)json_object_put(record);pthread_mutex_unlock(&s->mutex);return-1;}
    uint32_t effective_color=group->color_rgb;
    if(has_color)effective_color=color_rgb;
    else if(modifying){
        json_object*old_group=NULL,*old_color=NULL;
        const char*old_group_id=NULL;
        if(json_object_object_get_ex(record,"groupID",&old_group)&&json_object_is_type(old_group,json_type_string))old_group_id=json_object_get_string(old_group);
        if(old_group_id&&!strcasecmp(old_group_id,group->id)&&json_object_object_get_ex(record,"colorRGB",&old_color)&&json_object_is_type(old_color,json_type_int)){
            int64_t old=json_object_get_int64(old_color);if(old>=0&&old<=0x00ffffff)effective_color=(uint32_t)old;
        }
    }
    json_object_object_add(record,"login",json_object_new_string(login));
    json_object_object_add(record,"name",json_object_new_string(name));
    if(local_only)json_object_object_del(record,"legacyPassword");
    else if(s->legacy_compatible)json_object_object_add(record,"legacyPassword",json_object_new_string(password));else json_object_object_del(record,"legacyPassword");
    if(!preserve_password)json_object_object_add(record,"passwordVerifier",verifier);
    json_object_object_add(record,"mode",json_object_new_string(mode_json_name(effective_mode)));
    json_object_object_add(record,"groupID",json_object_new_string(group->id));
    json_object_object_add(record,"colorRGB",json_object_new_int64(effective_color));
    json_object_object_add(record,"personalDirectory",json_object_new_string(personal_string_from_bits(permission_bits)));
    json_object_object_add(record,"permissions",perms);
    json_object_object_add(record,"permissionsOverrideGroupDefaults",
                           json_object_new_boolean(supported_permission_bits(permission_bits)!=group->permission_bits));
    json_object_object_add(record,"colorOverridesGroupDefault",
                           json_object_new_boolean(effective_color!=group->color_rgb));
    json_object_object_add(record,"modifiedAt",json_object_new_string(now));
    if(!modifying)json_object_array_add(arr,record);
    json_object_array_sort(arr,account_json_compare);
    int rc=cr_state_save_locked(s);
    if(rc==0)rc=cr_state_refresh_parsed_locked(s);
    pthread_mutex_unlock(&s->mutex);
    if(rc==0&&action_out)*action_out=modifying?1:0;
    return rc;
}

int cr_state_account_set_picture(cr_server_state*s,const char*login,const uint8_t*picture,size_t picture_len){
    if(!s||!login||!*login||picture_len>UINT16_MAX||(picture_len&&!picture))return-1;
    pthread_mutex_lock(&s->mutex);json_object*arr=NULL;size_t idx;
    if(!json_object_object_get_ex(s->root,"accounts",&arr)||json_account_index_casefold(arr,login,&idx)!=0){pthread_mutex_unlock(&s->mutex);return-1;}
    json_object*record=json_object_array_get_idx(arr,idx);char*encoded=picture_len?base64_encode(picture,picture_len):NULL;
    if(picture_len&&!encoded){pthread_mutex_unlock(&s->mutex);return-1;}
    if(picture_len)json_object_object_add(record,"picture",json_object_new_string(encoded));else json_object_object_del(record,"picture");free(encoded);
    char now[64];cr_now_iso8601(now);json_object_object_add(record,"modifiedAt",json_object_new_string(now));
    int rc=cr_state_save_locked(s);if(rc==0)rc=cr_state_refresh_parsed_locked(s);pthread_mutex_unlock(&s->mutex);return rc;
}

static int valid_group_files_root(const cr_account_group *g){
    if(!g)return 0;
    const char *p=g->files_root_path;size_t n=strlen(p);
    if(n>1024)return 0;
    if(!n)return 1;
    size_t rn=strlen(g->files_root_name);if(!rn||rn>64||p[0]=='/'||p[n-1]=='/')return 0;
    int has_name_text=0;for(size_t i=0;i<rn;i++)if(!isspace((unsigned char)g->files_root_name[i])){has_name_text=1;break;}if(!has_name_text)return 0;
    const char *start=p;for(const char *q=p;;q++){
        if(*q=='/'||!*q){size_t len=(size_t)(q-start);if(!len||len>252||(len==1&&start[0]=='.')||(len==2&&start[0]=='.'&&start[1]=='.'))return 0;if(!*q)break;start=q+1;}
    }
    return 1;
}

int cr_state_set_account_groups(cr_server_state *s,const cr_account_group *groups,size_t count){
    if(!s||count!=3||!groups)return-1;
    const cr_account_group*ordered[3]={NULL,NULL,NULL};
    for(size_t i=0;i<count;i++){
        if(!groups[i].id[0]||strlen(groups[i].id)>63||groups[i].color_rgb>0x00ffffffu||!valid_group_files_root(&groups[i])||
           strcasecmp(groups[i].id,fixed_group_id(groups[i].mode)))return-1;
        size_t slot=groups[i].mode==CR_MODE_ADMIN?0:groups[i].mode==CR_MODE_ACCOUNT?1:2;
        if(ordered[slot]) return -1;
        ordered[slot] = &groups[i];
    }
    if(!ordered[0]||!ordered[1]||!ordered[2])return-1;
    pthread_mutex_lock(&s->mutex);
    json_object *array=json_object_new_array();if(!array){pthread_mutex_unlock(&s->mutex);return-1;}
    for(size_t slot=0;slot<3;slot++){
        const cr_account_group*src=ordered[slot];cr_account_mode mode=slot==0?CR_MODE_ADMIN:slot==1?CR_MODE_ACCOUNT:CR_MODE_GUEST;
        json_object*g=json_object_new_object(),*perms=permissions_json_from_bits(src->permission_bits);if(!g||!perms){if(g)json_object_put(g);if(perms)json_object_put(perms);json_object_put(array);pthread_mutex_unlock(&s->mutex);return-1;}
        json_object_object_add(g,"id",json_object_new_string(fixed_group_id(mode)));json_object_object_add(g,"name",json_object_new_string(default_group_name(mode)));json_object_object_add(g,"colorRGB",json_object_new_int64(src->color_rgb));json_object_object_add(g,"legacyMode",json_object_new_string(mode_json_name(mode)));json_object_object_add(g,"permissions",perms);json_object_object_add(g,"filesRootPath",json_object_new_string(src->files_root_path));json_object_object_add(g,"filesRootName",json_object_new_string(src->files_root_path[0]?src->files_root_name:"Allgemein"));json_object_array_add(array,g);
    }

    /*
     * Existing accounts store effective permissions/color so they can have individual overrides.
     * If an account still exactly matches its group's previous defaults, it is an inherited value:
     * advance it to the new defaults. Values that differ are explicit per-account overrides and
     * remain untouched. This makes group edits apply to normal members without requiring account
     * deletion/recreation.
     */
    json_object*accounts=NULL;
    if(json_object_object_get_ex(s->root,"accounts",&accounts)&&json_object_is_type(accounts,json_type_array)){
        char now[64];cr_now_iso8601(now);
        for(size_t ai=0;ai<json_object_array_length(accounts);ai++){
            json_object*a=json_object_array_get_idx(accounts,ai),*gidv=NULL;
            if(!json_object_object_get_ex(a,"groupID",&gidv)||!json_object_is_type(gidv,json_type_string))continue;
            const char*gid=json_object_get_string(gidv);if(!gid||!*gid)continue;

            const cr_account_group*previous=NULL,*updated=NULL;
            for(size_t gi=0;gi<s->account_group_count;gi++)
                if(!strcasecmp(s->account_groups[gi].id,gid)){previous=&s->account_groups[gi];break;}
            for(size_t slot=0;slot<3;slot++)
                if(!strcasecmp(ordered[slot]->id,gid)){updated=ordered[slot];break;}
            if(!previous||!updated)continue;

            if(json_bool_default(a,"localLoginOnly",0))continue;
            int changed=0;

            if(!json_bool_default(a,"permissionsOverrideGroupDefaults",0)){
                uint64_t account_bits=json_permission_bits(a);
                if(account_bits!=updated->permission_bits){
                    json_object*perms=permissions_json_from_bits(updated->permission_bits);
                    if(!perms){json_object_put(array);pthread_mutex_unlock(&s->mutex);return-1;}
                    json_object_object_add(a,"permissions",perms);changed=1;
                }
                json_object_object_add(a,"permissionsOverrideGroupDefaults",json_object_new_boolean(0));
            }

            if(!json_bool_default(a,"colorOverridesGroupDefault",0)){
                json_object*colorv=NULL;uint32_t color=previous->color_rgb;
                if(json_object_object_get_ex(a,"colorRGB",&colorv)&&json_object_is_type(colorv,json_type_int)){
                    int64_t raw=json_object_get_int64(colorv);if(raw>=0&&raw<=0x00ffffff)color=(uint32_t)raw;
                }
                if(color!=updated->color_rgb){
                    json_object_object_add(a,"colorRGB",json_object_new_int64(updated->color_rgb));changed=1;
                }
                json_object_object_add(a,"colorOverridesGroupDefault",json_object_new_boolean(0));
            }
            if(changed)json_object_object_add(a,"modifiedAt",json_object_new_string(now));
        }
    }

    json_object_object_add(s->root,"accountGroups",array);
    int rc=cr_state_save_locked(s);if(rc==0)rc=cr_state_refresh_parsed_locked(s);pthread_mutex_unlock(&s->mutex);return rc;
}

int cr_state_account_change_password(cr_server_state *s,const char *account_id,const char *password){
    if(!account_id||!*account_id||!password||strlen(password)>511)return-1;
    json_object*verifier=make_password_verifier(password);if(!verifier)return-1;
    pthread_mutex_lock(&s->mutex);
    json_object*arr=NULL,*record=NULL;
    if(json_object_object_get_ex(s->root,"accounts",&arr)&&json_object_is_type(arr,json_type_array)){
        for(size_t i=0;i<json_object_array_length(arr);i++){
            json_object*a=json_object_array_get_idx(arr,i),*idv=NULL;
            if(json_object_object_get_ex(a,"id",&idv)&&!strcmp(json_object_get_string(idv),account_id)){record=a;break;}
        }
    }
    if(!record||json_bool_default(record,"localLoginOnly",0)){pthread_mutex_unlock(&s->mutex);json_object_put(verifier);return-1;}
    if(s->legacy_compatible)json_object_object_add(record,"legacyPassword",json_object_new_string(password));
    else json_object_object_del(record,"legacyPassword");
    json_object_object_add(record,"passwordVerifier",verifier);
    char now[64];cr_now_iso8601(now);json_object_object_add(record,"modifiedAt",json_object_new_string(now));
    int rc=cr_state_save_locked(s);if(rc==0)rc=cr_state_refresh_parsed_locked(s);
    pthread_mutex_unlock(&s->mutex);return rc;
}

int cr_state_account_delete(cr_server_state *s,const char *login){
    pthread_mutex_lock(&s->mutex);json_object*arr=NULL;size_t idx;
    if(!json_object_object_get_ex(s->root,"accounts",&arr)||json_account_index_casefold(arr,login,&idx)!=0){pthread_mutex_unlock(&s->mutex);return-1;}
    json_object*record=json_object_array_get_idx(arr,idx),*idv=NULL;
    if(json_bool_default(record,"localLoginOnly",0)||(json_object_object_get_ex(record,"id",&idv)&&json_object_is_type(idv,json_type_string)&&!strcasecmp(json_object_get_string(idv),CR_LOCAL_BOT_ACCOUNT_ID))){pthread_mutex_unlock(&s->mutex);return-1;}
    if(json_object_array_del_idx(arr,idx,1)!=0){pthread_mutex_unlock(&s->mutex);return-1;}
    int rc=cr_state_save_locked(s);if(rc==0)rc=cr_state_refresh_parsed_locked(s);pthread_mutex_unlock(&s->mutex);return rc;
}

static json_object *newsgroup_access_json(uint16_t flags){
    json_object*a=json_object_new_object();if(!a)return NULL;
    json_object_object_add(a,"administratorsRead",json_object_new_boolean((flags&0x8000)!=0));
    json_object_object_add(a,"administratorsPost",json_object_new_boolean((flags&0x4000)!=0));
    json_object_object_add(a,"accountHoldersRead",json_object_new_boolean((flags&0x2000)!=0));
    json_object_object_add(a,"accountHoldersPost",json_object_new_boolean((flags&0x1000)!=0));
    json_object_object_add(a,"guestsRead",json_object_new_boolean((flags&0x0800)!=0));
    json_object_object_add(a,"guestsPost",json_object_new_boolean((flags&0x0400)!=0));
    return a;
}
int cr_state_newsgroup_create(cr_server_state*s,const char*name,uint32_t expire,uint16_t flags){
    if(!name||!*name||strlen(name)>511)return-1;
    pthread_mutex_lock(&s->mutex);json_object*arr=NULL;if(!json_object_object_get_ex(s->root,"newsgroups",&arr)){arr=json_object_new_array();json_object_object_add(s->root,"newsgroups",arr);}size_t idx;if(json_group_index_casefold(arr,name,&idx)==0){pthread_mutex_unlock(&s->mutex);return-1;}json_object*g=json_object_new_object(),*access=newsgroup_access_json(flags);if(!g||!access){if(g)json_object_put(g);if(access)json_object_put(access);pthread_mutex_unlock(&s->mutex);return-1;}char uuid[64];make_uuid(uuid);json_object_object_add(g,"id",json_object_new_string(uuid));json_object_object_add(g,"name",json_object_new_string(name));json_object_object_add(g,"articleCount",json_object_new_int64(0));json_object_object_add(g,"expireAfterSeconds",json_object_new_int64(expire));json_object_object_add(g,"access",access);json_object_array_add(arr,g);json_object_array_sort(arr,group_json_compare);int rc=cr_state_save_locked(s);if(rc==0)rc=cr_state_refresh_parsed_locked(s);pthread_mutex_unlock(&s->mutex);return rc;
}
int cr_state_newsgroup_modify(cr_server_state*s,const char*old_name,const char*new_name,uint32_t expire,uint16_t flags){
    if(!old_name||!*old_name||!new_name||!*new_name)return-1;
    pthread_mutex_lock(&s->mutex);json_object*arr=NULL;size_t idx,conflict;if(!json_object_object_get_ex(s->root,"newsgroups",&arr)||json_group_index_casefold(arr,old_name,&idx)!=0){pthread_mutex_unlock(&s->mutex);return-1;}if(json_group_index_casefold(arr,new_name,&conflict)==0&&conflict!=idx){pthread_mutex_unlock(&s->mutex);return-1;}json_object*g=json_object_array_get_idx(arr,idx),*access=newsgroup_access_json(flags);if(!access){pthread_mutex_unlock(&s->mutex);return-1;}json_object_object_add(g,"name",json_object_new_string(new_name));json_object_object_add(g,"expireAfterSeconds",json_object_new_int64(expire));json_object_object_add(g,"access",access);json_object_array_sort(arr,group_json_compare);int rc=cr_state_save_locked(s);if(rc==0)rc=cr_state_refresh_parsed_locked(s);pthread_mutex_unlock(&s->mutex);return rc;
}
int cr_state_newsgroup_delete(cr_server_state*s,const char*name){
    pthread_mutex_lock(&s->mutex);json_object*arr=NULL;size_t idx;if(!json_object_object_get_ex(s->root,"newsgroups",&arr)||json_group_index_casefold(arr,name,&idx)!=0){pthread_mutex_unlock(&s->mutex);return-1;}if(json_object_array_del_idx(arr,idx,1)!=0){pthread_mutex_unlock(&s->mutex);return-1;}int rc=cr_state_save_locked(s);if(rc==0)rc=cr_state_refresh_parsed_locked(s);pthread_mutex_unlock(&s->mutex);return rc;
}


int cr_state_set_newsgroup_article_count(cr_server_state*s,const char*group_id,uint32_t count){
    pthread_mutex_lock(&s->mutex);json_object*arr=NULL;int found=0;
    if(json_object_object_get_ex(s->root,"newsgroups",&arr)&&json_object_is_type(arr,json_type_array)){
        for(size_t i=0;i<json_object_array_length(arr);i++){json_object*g=json_object_array_get_idx(arr,i),*v=NULL;if(json_object_object_get_ex(g,"id",&v)&&!strcasecmp(json_object_get_string(v),group_id)){json_object_object_add(g,"articleCount",json_object_new_int64(count));found=1;break;}}
    }
    int rc=found?cr_state_save_locked(s):-1;
    if(!rc)for(size_t i=0;i<s->newsgroup_count;i++)if(!strcasecmp(s->newsgroups[i].id,group_id)){s->newsgroups[i].article_count=count;break;}
    pthread_mutex_unlock(&s->mutex);return rc;
}
