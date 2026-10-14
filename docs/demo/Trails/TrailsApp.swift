import SwiftUI

/// A small demo app for the README screenshots. Set TRAILS_API to a base URL to make it load from a server, which
/// gives the network monitor something to show.
@main
struct TrailsApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

struct Trail: Identifiable, Decodable, Hashable {
    let id: Int
    let name: String
    let region: String
    let distance: Double
    let climb: Int
    let rating: Double
    let hue: Double

    static let samples = [
        Trail(id: 1, name: "Lakeside Loop", region: "Lake District", distance: 7.4, climb: 312, rating: 4.8, hue: 0.55),
        Trail(id: 2, name: "Pine Ridge", region: "Black Forest", distance: 11.2, climb: 640, rating: 4.6, hue: 0.36),
        Trail(id: 3, name: "Sunset Cliffs", region: "Algarve Coast", distance: 5.1, climb: 140, rating: 4.9, hue: 0.07),
        Trail(id: 4, name: "Glacier View", region: "Jotunheimen", distance: 14.8, climb: 980, rating: 4.7, hue: 0.6),
        Trail(id: 5, name: "Old Mill Path", region: "Cotswolds", distance: 4.3, climb: 85, rating: 4.4, hue: 0.12),
    ]
}

struct RootView: View {
    var body: some View {
        TabView {
            ExploreView().tabItem { Label("Explore", systemImage: "map") }
            Text("Saved trails").tabItem { Label("Saved", systemImage: "bookmark") }
            Text("Your profile").tabItem { Label("Profile", systemImage: "person.crop.circle") }
        }
        .tint(.green)
    }
}

struct ExploreView: View {
    @State private var trails = Trail.samples
    @State private var search = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    FeaturedCard(trail: trails[0])
                    HStack {
                        Text("Near you").font(.title3.bold())
                        Spacer()
                        Text("See all").font(.subheadline.weight(.semibold)).foregroundStyle(.green)
                    }
                    ForEach(trails.dropFirst()) { trail in
                        TrailRow(trail: trail)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .navigationTitle("Trails")
            .searchable(text: $search, prompt: "Search trails")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {} label: { Image(systemName: "slider.horizontal.3") }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let base = ProcessInfo.processInfo.environment["TRAILS_API"].flatMap(URL.init(string:)) else { return }
        let session = URLSession(configuration: .default)
        if let (data, _) = try? await session.data(from: base.appending(path: "api/trails")),
           let loaded = try? JSONDecoder().decode([Trail].self, from: data), !loaded.isEmpty {
            trails = loaded
        }
        _ = try? await session.data(from: base.appending(path: "api/weather").appending(queryItems: [URLQueryItem(name: "lat", value: "54.46"), URLQueryItem(name: "lon", value: "-3.02")]))
        var favourite = URLRequest(url: base.appending(path: "api/favourites"))
        favourite.httpMethod = "POST"
        favourite.setValue("application/json", forHTTPHeaderField: "Content-Type")
        favourite.httpBody = Data(#"{"trail":1,"note":"Go at sunrise"}"#.utf8)
        _ = try? await session.data(for: favourite)
        _ = try? await session.data(from: base.appending(path: "api/trails/99"))
    }
}

struct FeaturedCard: View {
    let trail: Trail

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Landscape(hue: trail.hue)
                .frame(height: 210)
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                Text("TRAIL OF THE WEEK").font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.85))
                Text(trail.name).font(.title2.bold()).foregroundStyle(.white)
                Label("\(trail.distance, specifier: "%.1f") km · \(trail.climb) m climb", systemImage: "figure.hiking")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct TrailRow: View {
    let trail: Trail

    var body: some View {
        HStack(spacing: 14) {
            Landscape(hue: trail.hue)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(trail.name).font(.headline)
                Text(trail.region).font(.subheadline).foregroundStyle(.secondary)
                Text("\(trail.distance, specifier: "%.1f") km · \(trail.climb) m").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Label("\(trail.rating, specifier: "%.1f")", systemImage: "star.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Layered hills and a sun, drawn in code so the demo needs no image assets.
struct Landscape: View {
    let hue: Double

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                LinearGradient(
                    colors: [Color(hue: hue, saturation: 0.35, brightness: 1), Color(hue: hue, saturation: 0.55, brightness: 0.85)],
                    startPoint: .top, endPoint: .bottom
                )
                Circle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: size.width * 0.16)
                    .position(x: size.width * 0.74, y: size.height * 0.32)
                Hills(peak: 0.42, phase: 0.2).fill(Color(hue: hue, saturation: 0.45, brightness: 0.62))
                Hills(peak: 0.58, phase: 1.1).fill(Color(hue: hue, saturation: 0.6, brightness: 0.45))
                Hills(peak: 0.74, phase: 2.3).fill(Color(hue: hue, saturation: 0.7, brightness: 0.3))
            }
        }
    }
}

struct Hills: Shape {
    let peak: Double
    let phase: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.maxY))
        for step in 0...40 {
            let x = Double(step) / 40
            let y = peak + 0.08 * sin(x * 7 + phase) + 0.05 * sin(x * 13 + phase * 2)
            path.addLine(to: CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
