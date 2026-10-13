#pragma once
#include "common.hpp"
#include <condition_variable>

namespace inn {
// WinRT Completed may be assigned only once. Keep the callback state alive
// even when cancellation returns before the provider finishes its operation.
template<class Op> auto await_native(Op const& op,Cancel const& cancel){
    struct Completion {std::mutex mutex;std::condition_variable changed;bool done=false;};
    auto state=std::make_shared<Completion>();
    try {
        op.Completed([state](auto const&,auto const&){
            {std::lock_guard lock(state->mutex);state->done=true;}
            state->changed.notify_all();
        });
        std::unique_lock lock(state->mutex);
        while(!state->done){
            cancel.check();
            state->changed.wait_for(lock,std::chrono::milliseconds(20),[&]{return state->done;});
        }
        lock.unlock();
        cancel.check();
        return op.GetResults();
    }catch(...){try{op.Cancel();}catch(...){}throw;}
}
}