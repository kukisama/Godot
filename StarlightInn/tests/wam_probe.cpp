#include "common.hpp"
#include <iostream>
// No settings/profile/identity/account/token/HTTP call, no HWND or visible UI.
int main(){
    using namespace inn;
    bool initialized=false;
    try{
        native_call(NativeStage::WinrtInit,[]{winrt::init_apartment(winrt::apartment_type::multi_threaded);});initialized=true;
        J result;put(result,"authentication_performed",false);put(result,"personal_profile_read",false);put(result,"cloud_called",false);
        try{NativeIdentity::verify_factory();put(result,"factory_hresult","0x00000000");put(result,"interop_ready",true);}
        catch(NativeFailure const& e){put(result,"factory_hresult",hex_code(e.hresult));put(result,"interop_ready",false);put(result,"factory_diagnostic",e.dto());}
        try{Cancel c;put(result,"provider_exists",NativeIdentity::discover_provider(c));put(result,"provider_hresult","0x00000000");}
        catch(NativeFailure const& e){put(result,"provider_exists",false);put(result,"provider_hresult",hex_code(e.hresult));put(result,"provider_code",e.code());}
        catch(Error const&){put(result,"provider_exists",false);put(result,"provider_code","DISCOVERY_CANCELLED_OR_TIMEOUT");}
        std::cout<<encode(result)<<"\n";
    }catch(NativeFailure const& e){std::cout<<"{\"stage\":\"winrt_init\",\"hresult\":\""<<hex_code(e.hresult)<<"\",\"authentication_performed\":false}\n";return 1;}
    if(initialized)winrt::uninit_apartment();return 0;
}