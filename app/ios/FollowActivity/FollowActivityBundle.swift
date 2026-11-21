import SwiftUI
import WidgetKit

@main
struct FollowActivityBundle: WidgetBundle {
  var body: some Widget {
    if #available(iOS 16.1, *) {
      FollowActivityLiveActivity()
    }
  }
}
