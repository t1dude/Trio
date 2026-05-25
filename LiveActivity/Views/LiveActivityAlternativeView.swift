import ActivityKit
import Charts
import SwiftUI
import WidgetKit

struct LiveActivityAlternativeView: View {
    @Environment(\.colorScheme) var colorScheme

    var context: ActivityViewContext<LiveActivityAttributes>
    var glucoseColor: Color

    private let angularGradient = AngularGradient(
        colors: [
            Color(red: 0.7215686275, green: 0.3411764706, blue: 1),
            Color(red: 0.6235294118, green: 0.4235294118, blue: 0.9803921569),
            Color(red: 0.4862745098, green: 0.5450980392, blue: 0.9529411765),
            Color(red: 0.3411764706, green: 0.6666666667, blue: 0.9254901961),
            Color(red: 0.262745098, green: 0.7333333333, blue: 0.9137254902),
            Color(red: 0.7215686275, green: 0.3411764706, blue: 1)
        ],
        center: .center,
        startAngle: .degrees(270),
        endAngle: .degrees(-90)
    )

    private let triangleColor = Color(red: 0.262745098, green: 0.7333333333, blue: 0.9137254902)
    private let circleSize: CGFloat = 100

    private var arrowSize: CGFloat { circleSize * (35.0 / 130.0) }
    private var arrowOffset: CGFloat { circleSize * (85.0 / 130.0) }

    var body: some View {
        if context.state.isInitialState {
            Text("Live Activity Expired. Open Trio to Refresh").minimumScaleFactor(0.01)
        } else {
            let hasActive = context.state.detailedViewState.isOverrideActive ||
                context.state.detailedViewState.isTempTargetActive
            HStack(alignment: hasActive ? .top : .center, spacing: 10) {
                glucoseCircle
                rightPanel
            }
        }
    }

    private var glucoseCircle: some View {
        let hasOverride = context.state.detailedViewState.isOverrideActive
        let hasTT = context.state.detailedViewState.isTempTargetActive
        let activeCount = (hasOverride ? 1 : 0) + (hasTT ? 1 : 0)
        // Total badge area = two 12pt pills + 2pt gap; single active pill expands to fill all of it
        let badgeAreaHeight: CGFloat = 26
        let pillHeight: CGFloat = activeCount == 1 ? badgeAreaHeight : (badgeAreaHeight - 2) / 2
        let badgeFontSize: CGFloat = activeCount == 1 ? 12 : 8

        return VStack(spacing: 8) {
            ZStack {
                AlternativeWidgetTrendCircle(
                    gradient: angularGradient,
                    color: triangleColor,
                    size: circleSize
                )
                .rotationEffect(.degrees(context.state.detailedViewState.rotationDegrees))

                VStack(spacing: 1) {
                    Text(context.state.bg)
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.5)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(context.isStale ? Color.secondary : Color.white)
                        .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))

                    Text(context.state.change.isEmpty ? "--" : context.state.change)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(context.isStale ? Color.secondary : Color.white)
                        .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))
                }
            }
            .frame(width: circleSize, height: circleSize)

            if hasOverride || hasTT {
                VStack(spacing: 2) {
                    if hasOverride {
                        Text(context.state.detailedViewState.overrideName)
                            .font(.system(size: badgeFontSize, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 4)
                            .frame(width: circleSize, height: pillHeight)
                            .background {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.purple.opacity(colorScheme == .dark ? 0.6 : 0.8))
                            }
                    }
                    if hasTT {
                        Text(context.state.detailedViewState.tempTargetName)
                            .font(.system(size: badgeFontSize, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 4)
                            .frame(width: circleSize, height: pillHeight)
                            .background {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color("LoopGreen").opacity(colorScheme == .dark ? 0.6 : 0.8))
                            }
                    }
                }
            }
        }
        .frame(width: circleSize)
    }

    private var rightPanel: some View {
        VStack(spacing: 4) {
            LiveActivityChartView(context: context, additionalState: context.state.detailedViewState)
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            kpiRow
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var kpiRow: some View {
        let items = Array(
            context.state.detailedViewState.widgetItems
                .filter { $0 != .empty }
                .prefix(3)
                .enumerated()
        )

        return HStack(spacing: 0) {
            ForEach(items, id: \.offset) { index, widgetItem in
                if index > 0 {
                    Divider().padding(.vertical, 6)
                }
                kpiItem(widgetItem)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder private func kpiItem(_ item: LiveActivityAttributes.LiveActivityItem) -> some View {
        switch item {
        case .currentGlucose:
            VStack {
                LiveActivityBGLabelView(context: context, additionalState: context.state.detailedViewState)
                HStack {
                    LiveActivityGlucoseDeltaLabelView(context: context, glucoseColor: .primary)
                    if !context.isStale, let direction = context.state.direction {
                        Text(direction).font(.headline)
                    }
                }
            }
        case .currentGlucoseLarge:
            LiveActivityBGLabelLargeView(context: context, glucoseColor: glucoseColor)
        case .iob:
            LiveActivityIOBLabelView(context: context, additionalState: context.state.detailedViewState)
        case .cob:
            LiveActivityCOBLabelView(context: context, additionalState: context.state.detailedViewState)
        case .updatedLabel:
            LiveActivityUpdatedLabelView(context: context, isDetailedLayout: true)
        case .totalDailyDose:
            LiveActivityTotalDailyDoseView(context: context, additionalState: context.state.detailedViewState)
        case .totalDailyDoseCalendarDay:
            LiveActivityTotalDailyDoseCalendarDayView(context: context, additionalState: context.state.detailedViewState)
        case .eventualBG:
            LiveActivityGlucoseForecastView(context: context, additionalState: context.state.detailedViewState)
        case .empty:
            EmptyView()
        }
    }
}

// MARK: - Circle + arrow component

/// Gradient stroke circle with a directional arrow, scaled to the given size.
/// Mirrors the TrendShape used on the main app's home screen.
struct AlternativeWidgetTrendCircle: View {
    let gradient: AngularGradient
    let color: Color
    let size: CGFloat

    private var lineWidth: CGFloat { size * (6.0 / 130.0) }
    private var arrowSize: CGFloat { size * (35.0 / 130.0) }
    private var arrowOffset: CGFloat { size * (85.0 / 130.0) }

    var body: some View {
        ZStack {
            Group {
                Circle()
                    .stroke(gradient, lineWidth: lineWidth)
                    .background(Circle().fill(.clear))
                    .frame(width: size, height: size)

                TrendArrow()
                    .fill(color)
                    .frame(width: arrowSize, height: arrowSize)
                    .rotationEffect(.degrees(90))
                    .offset(x: arrowOffset)
            }
            .shadow(color: .black.opacity(0.5), radius: 3)

            // Redraw circle on top so stroke stays crisp over the shadow
            Circle()
                .stroke(gradient, lineWidth: lineWidth)
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
    }
}

/// Identical to the Triangle shape used in CurrentGlucoseView on the main app's home screen.
/// Tip sits 15/35 from the top edge; the base is gently concave inward.
private struct TrendArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * (15.0 / 35.0)))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY),
            control: CGPoint(x: rect.midX, y: rect.midY + rect.height * (10.0 / 35.0))
        )
        path.closeSubpath()
        return path
    }
}
