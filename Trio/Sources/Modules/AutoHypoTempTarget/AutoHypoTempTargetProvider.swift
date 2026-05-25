extension AutoHypoTempTarget {
    final class Provider: BaseProvider, AutoHypoTempTargetProvider {
        @Injected() var tempTargetsStorage: TempTargetsStorage!
    }
}
