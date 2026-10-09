#pragma once
#include "common.hpp"
#include <optional>
namespace inn {
// Single dispatcher owns requests/poll steps. Only controls run on the reader.
// Every externally observable mutable state is protected by mutex.
class Core {
    struct Snapshot {J context;std::shared_ptr<Lease> lease;Cancel cancel;};
    struct Ticket {J dto;Clock::time_point expires;};
    struct Job {J dto;std::shared_ptr<Lease> lease;std::string poll;bool async=false,ack=false;unsigned count=0;Clock::time_point due,deadline;};
    Identity& identity;Http& http;Profiles& profiles;
    std::mutex mutex;
    Settings settings;
    Profile profile;
    J context;
    std::map<std::string,J> tenants,subs,vms;
    std::map<std::string,std::string> next;
    std::map<std::string,Ticket> tickets;
    std::map<std::string,Job> jobs;
    std::shared_ptr<Lease> lease;
    std::shared_ptr<std::atomic_bool> query=std::make_shared<std::atomic_bool>(false),auth=std::make_shared<std::atomic_bool>(false);
    std::shared_ptr<std::atomic_bool> lifetime=std::make_shared<std::atomic_bool>(false);
    unsigned long generation=0,auth_generation=0;
    bool restoring=false,auth_busy=false;
    std::string notice="请首次手动登录；原 MSAL 档案未读取，新版本使用明确 WAM 账户。";
    std::function<Clock::time_point()> now;
    void advance(std::string const&,std::string const&,std::string const&,std::string const&,std::string const&);
    Snapshot capture(bool sub=true);
    void check(Snapshot const&);
    Response send(std::shared_ptr<Lease>,std::string const&,std::string const&,Cancel const&);
    J get(std::shared_ptr<Lease>,std::string const&,Cancel const&);
    J mapvm(J const&,std::string const&);
    J readvm(std::shared_ptr<Lease>,J const&,std::string const&,Cancel const&);
    J named(std::string const&,bool);
    J listvms(bool);
    J inspect(std::string const&);
    J prepare(std::string const&,std::string const&);
    J execute(std::string const&);
    void no_active(std::string const&);
    void known(Snapshot const&,std::string const&);
    void remember();
    void save(Profile const&);
    J login(J const&,HWND,std::optional<unsigned long>);
    J restore(std::optional<unsigned long>);
    void logout(std::optional<unsigned long>);
    void update(Job&,const char*,const char*);
    J prefs_locked();
public:
    std::chrono::seconds ttl{120},poll_budget{600};
    unsigned max_polls=40,max_restore_pages=10;
    std::function<void(Settings const&)> persist;
    Core(Identity&,Http&,Profiles&,std::function<Clock::time_point()> clock=[](){return Clock::now();});
    void configure(Settings const&);
    void control(std::string const&);
    unsigned long authGeneration();
    // Expected generation is stamped by the trusted reader, never wire input.
    J dispatch(std::string const&,std::string const&,J const&,HWND=nullptr,std::optional<unsigned long> expectedAuthGeneration=std::nullopt);
    J current();J preferences();A operations();J configuration();
    void tick();
    void shutdown();
};
}