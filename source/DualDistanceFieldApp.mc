import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

class DualDistanceFieldApp extends Application.AppBase {

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state as Dictionary?) as Void {
    }

    function onStop(state as Dictionary?) as Void {
    }

    function getInitialView() as [Views] or [Views, InputDelegates] {
        return [ new DualDistanceFieldView() ];
    }

}

function getApp() as DualDistanceFieldApp {
    return Application.getApp() as DualDistanceFieldApp;
}
