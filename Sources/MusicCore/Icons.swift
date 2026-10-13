import Foundation

/// Icons Nerdwave can guess from a playlist's name. Single-word keywords match whole words (and
/// plurals/longer forms, for example "game" matches "games"); keywords with spaces match that phrase.
/// A playlist file can override the guess with an `#ICON: <SF Symbol name>` line.
public let playlistIconTable: [(symbol: String, keywords: [String])] = [
    ("cup.and.saucer.fill", ["chill", "lofi", "lo fi", "coffee", "cafe", "study", "relax", "mellow", "cozy", "low key", "lowkey"]),
    ("headphones", ["hip hop", "hiphop", "rap", "boom bap", "trap", "beats", "grime"]),
    ("gamecontroller.fill", ["game", "gaming", "gamer", "retro", "arcade", "8 bit", "8bit", "16 bit", "chiptune", "pixel", "nintendo", "rpg", "speedrun"]),
    ("moon.stars.fill", ["night", "late", "midnight", "sleep", "insomnia", "dream", "nocturnal", "lullaby"]),
    ("leaf.fill", ["calm", "ambient", "nature", "zen", "meditation", "peace", "peaceful", "serene", "spa", "yoga"]),
    ("guitars.fill", ["rock", "metal", "punk", "grunge", "guitar", "emo", "hardcore"]),
    ("flame.fill", ["epic", "boss", "battle", "intense", "action", "fight", "war", "combat", "raid", "hype"]),
    ("bolt.fill", ["upbeat", "energy", "energetic", "edm", "dance", "electro", "electronic", "drum and bass", "dnb",
                   "dubstep", "techno", "house", "trance", "rave", "club", "drop", "pulse"]),
    ("sunset.fill", ["synthwave", "retrowave", "outrun", "vaporwave", "sunset", "dusk", "neon"]),
    ("pianokeys", ["piano", "classical", "keys", "sonata", "chamber"]),
    ("music.quarternote.3", ["jazz", "blues", "swing", "soul", "funk", "bossa", "groove", "groovy"]),
    ("film.fill", ["cinematic", "soundtrack", "movie", "film", "score", "trailer", "ost", "orchestral", "orchestra"]),
    ("sparkles", ["magic", "fantasy", "fairy", "enchanted", "mystic", "dreamy", "whimsical"]),
    ("mountain.2.fill", ["adventure", "quest", "explore", "exploration", "journey", "expedition", "legend"]),
    ("heart.fill", ["love", "romance", "romantic", "r b", "rnb", "valentine", "crush"]),
    ("music.mic", ["pop", "vocal", "vocals", "karaoke", "sing", "singing", "ballad"]),
    ("snowflake", ["christmas", "xmas", "holiday", "holidays", "winter", "snow", "festive"]),
    ("cloud.rain.fill", ["rain", "rainy", "sad", "melancholy", "blue", "storm", "gloomy"]),
    ("sun.max.fill", ["summer", "sunny", "happy", "morning", "sunshine", "bright", "cheerful"]),
    ("water.waves", ["ocean", "sea", "beach", "surf", "waves", "tropical", "island"]),
    ("camera.macro", ["flower", "flowers", "sakura", "blossom", "spring", "rose", "garden", "floral", "pastel"]),
    ("eye.fill", ["halloween", "spooky", "horror", "creepy", "ghost", "haunted", "dark"]),
    ("party.popper.fill", ["party", "celebration", "fiesta", "birthday", "fun"]),
    ("figure.run", ["workout", "gym", "running", "run", "fitness", "training", "cardio"]),
    ("car.fill", ["drive", "driving", "road", "cruise", "cruising", "highway", "road trip"]),
    ("airplane", ["travel", "flight", "trip", "vacation", "abroad"]),
    ("building.2.fill", ["city", "urban", "street", "downtown", "metro", "subway"]),
    ("flag.checkered", ["race", "racing", "speed", "rally", "grand prix"]),
    ("chevron.left.forwardslash.chevron.right", ["code", "coding", "programming", "dev", "developer", "hacker", "hacking", "debug"]),
    ("brain.head.profile", ["focus", "deep work", "concentration", "productivity", "work", "thinking"]),
    ("book.fill", ["reading", "read", "library", "book", "books", "story"]),
    ("crown.fill", ["royal", "king", "queen", "kingdom", "majestic", "supreme", "gold"]),
    ("suit.diamond.fill", ["diamond", "diamonds", "luxury", "lux", "bling", "jewel"]),
    ("globe.americas.fill", ["world", "latin", "reggae", "afro", "afrobeat", "global", "salsa", "kpop", "k pop", "jpop", "j pop"]),
    ("radio.fill", ["radio", "oldies", "vintage", "classic", "throwback", "nostalgia", "nostalgic"]),
    ("cat.fill", ["cat", "cats", "kitty", "neko"]),
    ("dog.fill", ["dog", "dogs", "puppy", "inu"]),
    ("tortoise.fill", ["slow", "slowed", "downtempo", "lazy"]),
    ("hare.fill", ["fast", "speedup", "sped up", "nightcore", "uptempo"]),
    ("theatermasks.fill", ["drama", "theater", "theatre", "musical", "broadway"]),
    ("trophy.fill", ["victory", "win", "winner", "champion", "champions", "ranked", "esports", "tournament"]),
    ("star.fill", ["favorite", "favorites", "favourites", "best", "top", "starred", "hits"]),
    ("hammer.fill", ["build", "building", "craft", "crafting", "minecraft", "sandbox"]),
    ("atom", ["science", "space", "cosmic", "galaxy", "sci fi", "scifi", "future", "futuristic", "planetarium"]),
    ("wand.and.stars", ["anime", "kawaii", "chibi", "otaku"]),
]

/// The fallback when nothing matches.
public let defaultPlaylistIcon = "music.note.list"

/// Lowercase words separated by single spaces, with spaces at both ends ("Hip-Hop!" -> " hip hop ").
func normalizedWords(_ s: String) -> String {
    let mapped = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
    return " " + String(mapped).split(separator: " ").joined(separator: " ") + " "
}

/// Guesses an SF Symbol for a playlist from its name. Words are read left to right and the first word
/// (or phrase starting there) that matches a keyword decides, because names usually lead with what
/// matters most ("Jazz Nights", "Late Night Lofi"). Ties at the same word go to the table order.
public func guessPlaylistIcon(_ name: String) -> String {
    let words = normalizedWords(name).split(separator: " ").map(String.init)
    let entries = playlistIconTable.map { entry in
        (entry.symbol, entry.keywords.map { normalizedWords($0).split(separator: " ").map(String.init) })
    }
    for start in words.indices {
        for (symbol, keywords) in entries {
            for k in keywords where !k.isEmpty {
                if k.count == 1 {
                    let w = words[start], key = k[0]
                    if w == key || (key.count >= 4 && w.hasPrefix(key)) { return symbol }
                } else if start + k.count <= words.count, Array(words[start..<(start + k.count)]) == k {
                    return symbol
                }
            }
        }
    }
    return defaultPlaylistIcon
}
