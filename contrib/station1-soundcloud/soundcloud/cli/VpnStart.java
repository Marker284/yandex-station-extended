import android.content.Intent;
import android.os.Bundle;
import java.lang.reflect.Method;

/** v2rayNG 1.9.45's existing Tasker start API, without a toggle or profile change. */
public final class VpnStart {
    public static void main(String[] args)throws Exception{
        Bundle command=new Bundle();
        command.putBoolean("tasker_extra_bundle_switch",true);
        command.putString("tasker_extra_bundle_guid","Default");
        Intent intent=new Intent("com.twofortyfouram.locale.intent.action.FIRE_SETTING");
        intent.setClassName("com.v2ray.ang","com.v2ray.ang.receiver.TaskerReceiver");
        intent.addFlags(Intent.FLAG_INCLUDE_STOPPED_PACKAGES);
        intent.putExtra("com.twofortyfouram.locale.intent.extra.BUNDLE",command);
        Object activity=Class.forName("android.app.ActivityManagerNative").getMethod("getDefault").invoke(null);
        for(Method method:Class.forName("android.app.IActivityManager").getMethods()){
            if(method.getName().equals("broadcastIntent")&&method.getParameterTypes().length==13){
                method.invoke(activity,new Object[]{null,intent,null,null,0,null,null,null,-1,null,false,false,0});
                return;
            }
        }
        throw new NoSuchMethodException("Android 6 broadcastIntent");
    }
}
