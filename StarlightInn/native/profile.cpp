#include "common.hpp"
#include <wincrypt.h>
#include <shlobj.h>
#include <filesystem>

namespace inn {
void Profile::validate()const{
    for(auto const* s:{&client,&initial,&account_id,&provider,&username,&tenant,&sub,&subname})require(clean(*s),"INVALID_PROFILE");
    if(account_id.empty()){require(client.empty()&&initial.empty()&&provider.empty()&&username.empty()&&tenant.empty()&&sub.empty()&&subname.empty(),"INVALID_PROFILE");return;}
    Settings{client,initial}.validate();require(provider=="https://login.microsoft.com"&&guid(tenant)&&!username.empty()&&(sub.empty()||guid(sub))&&(!sub.empty()||subname.empty()),"INVALID_PROFILE");
}
void Profile::match(Settings const& s)const{validate();s.validate();require(!account_id.empty()&&eq(client,s.client)&&eq(initial,s.initial),"PROFILE_MISMATCH");}
J Profile::dto()const{J j;put(j,"version",2.0);put(j,"auto_login",auto_login);put(j,"client_id",client);put(j,"initial_tenant",initial);put(j,"native_account_id",account_id);put(j,"provider",provider);put(j,"username",username);put(j,"tenant_id",tenant);put(j,"subscription_id",sub);put(j,"subscription_name",subname);return j;}
Profile Profile::from(J const& j){keys(j,{"version","auto_login","client_id","initial_tenant","native_account_id","provider","username","tenant_id","subscription_id","subscription_name"});require(j.Size()==10&&j.GetNamedNumber(L"version")==2,"INVALID_PROFILE");Profile p; p.auto_login=boolean(j,"auto_login");p.client=text(j,"client_id");p.initial=text(j,"initial_tenant");p.account_id=text(j,"native_account_id");p.provider=text(j,"provider");p.username=text(j,"username");p.tenant=text(j,"tenant_id");p.sub=text(j,"subscription_id");p.subname=text(j,"subscription_name");p.validate();return p;}
std::string read_file(std::wstring const& path,size_t limit){
    HANDLE h=CreateFileW(path.c_str(),GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);require(h!=INVALID_HANDLE_VALUE,"PROFILE_IO");
    LARGE_INTEGER size;bool ok=GetFileSizeEx(h,&size)&&size.QuadPart>0&&size.QuadPart<=static_cast<LONGLONG>(limit);std::string bytes;if(ok){bytes.resize(static_cast<size_t>(size.QuadPart));DWORD got=0;ok=ReadFile(h,bytes.data(),static_cast<DWORD>(bytes.size()),&got,nullptr)&&got==bytes.size();}CloseHandle(h);require(ok,"PROFILE_IO");return bytes;
}
void atomic_file(std::wstring const& path,std::string_view bytes){
    auto temp=path+L"."+wide(uuid())+L".tmp";
    HANDLE h=CreateFileW(temp.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);require(h!=INVALID_HANDLE_VALUE,"PROFILE_IO");DWORD n=0;bool ok=WriteFile(h,bytes.data(),static_cast<DWORD>(bytes.size()),&n,nullptr)&&n==bytes.size()&&FlushFileBuffers(h);CloseHandle(h);
    if(ok)ok=MoveFileExW(temp.c_str(),path.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)!=0;
    DeleteFileW(temp.c_str());require(ok,"PROFILE_IO");
}
namespace {
std::string protect(std::string const& bytes,bool encrypt){
    DATA_BLOB in{static_cast<DWORD>(bytes.size()),reinterpret_cast<BYTE*>(const_cast<char*>(bytes.data()))},out{};
    bool ok=encrypt?CryptProtectData(&in,nullptr,nullptr,nullptr,nullptr,CRYPTPROTECT_UI_FORBIDDEN,&out)!=0:CryptUnprotectData(&in,nullptr,nullptr,nullptr,nullptr,CRYPTPROTECT_UI_FORBIDDEN,&out)!=0;
    struct Cleanup {DATA_BLOB& blob;~Cleanup(){if(blob.pbData){SecureZeroMemory(blob.pbData,blob.cbData);LocalFree(blob.pbData);}}} cleanup{out};
    require(ok,"INVALID_PROFILE");return std::string(reinterpret_cast<char*>(out.pbData),out.cbData);
}
}
Profile DiskProfiles::load(){if(GetFileAttributesW(path.c_str())==INVALID_FILE_ATTRIBUTES){require(GetLastError()==ERROR_FILE_NOT_FOUND||GetLastError()==ERROR_PATH_NOT_FOUND,"PROFILE_IO");return {}; }Secret bytes(protect(read_file(path,16384),false));return Profile::from(parse(bytes.bytes,16384));}
void DiskProfiles::save(Profile const& p){p.validate();Secret plain(encode(p.dto()));auto encrypted=protect(plain.bytes,true);std::error_code ec;std::filesystem::create_directories(std::filesystem::path(path).parent_path(),ec);require(!ec,"PROFILE_IO");atomic_file(path,encrypted);}
std::wstring DiskProfiles::default_path(){PWSTR dir=nullptr;require(SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData,0,nullptr,&dir)),"PROFILE_IO");std::wstring p=dir;CoTaskMemFree(dir);return p+L"\\StarlightInn\\Azure\\session-profile.v2.bin";}
}