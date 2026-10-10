import Foundation
import SupersEmuKit

/// Pinned libretro-database DATs and libretro-thumbnails repos. Datasets are downloaded at runtime into
/// `<data-dir>/metadata/` and checked against these SHA-256s; nothing here is committed to the repo.
/// Bump the commits (and hashes: scripts/metadata-pins.sh <commit>) to pick up new dumps.
public struct MetadataCatalog: Sendable {
    public struct SystemSet: Sendable {
        /// libretro playlist name, used for both DAT filenames and the thumbnails repo.
        public var name: String
        /// `no-intro` or `redump`.
        public var source: String
        /// DAT kind (`source`, `genre`, `releaseyear`, `publisher`, `developer`, `maxusers`) -> SHA-256 of the file at `databaseCommit`.
        public var files: [String: String]
        public var thumbnailsCommit: String
    }

    public var databaseCommit: String
    public var systems: [SystemID: SystemSet]
    public var databaseBaseURL = URL(string: "https://raw.githubusercontent.com/libretro/libretro-database")!
    public var thumbnailsBaseURL = URL(string: "https://raw.githubusercontent.com/libretro-thumbnails")!

    public init(databaseCommit: String, systems: [SystemID: SystemSet]) {
        self.databaseCommit = databaseCommit
        self.systems = systems
    }

    public func datURL(_ set: SystemSet, kind: String) -> URL {
        let folder = kind == "source" ? set.source : kind
        return databaseBaseURL.appendingPathComponent(databaseCommit).appendingPathComponent("metadat")
            .appendingPathComponent(folder).appendingPathComponent("\(set.name).dat")
    }

    /// `kind` is `Named_Boxarts`, `Named_Titles` or `Named_Snaps`; `name` is already thumbnail-safe.
    public func thumbnailURL(_ set: SystemSet, kind: String, name: String) -> URL {
        thumbnailsBaseURL.appendingPathComponent(set.name.replacingOccurrences(of: " ", with: "_"))
            .appendingPathComponent(set.thumbnailsCommit).appendingPathComponent(kind).appendingPathComponent("\(name).png")
    }

    /// libretro-database @ 2026-10-08, libretro-thumbnails @ 2026-10-10.
    public static let pinned = MetadataCatalog(databaseCommit: "bf825e3ec48d43557ad024da6a7b93e512043525", systems: [
        .snes: SystemSet(name: "Nintendo - Super Nintendo Entertainment System", source: "no-intro", files: [
            "source": "76bb6fc95243d03c0842b0600c34c9a0e6e711be0027d7d4fe90330658ae20ec",
            "genre": "92f0ed22dfecf2bb8338f5680dd0b5556c70e6a63ab9fe36285d8c945649f67e",
            "releaseyear": "a38acd1af1d9f2aa9ebe9efaa74d2335fdb40aefff8512c9fd1dedf8577d3998",
            "publisher": "4a67c64944d7091903b7afc8f4982cd4d1e69ced383fe954da42409e5108380f",
            "developer": "d62b92756bc4b1dda0ca9a0a3572f9df00a9126b4d9b4b4f5c1becb77dafb85c",
            "maxusers": "7d0aaea14f67fd34b9d70e5b7b70c5a4c87a20e63d5e358b130ed773ee5fb68d",
        ], thumbnailsCommit: "cdd8f1d44612976cc9d422b0ace53a8542667688"),
        .gb: SystemSet(name: "Nintendo - Game Boy", source: "no-intro", files: [
            "source": "2dc0e5dd0ec696b60a4fc1987b1f84814a08cebc31138551f2e7ef9f11e10f74",
            "genre": "3d88c5579fdb2f9c6d828170defe34b89cd855792fbb937e3c6f50a51c4b63c2",
            "releaseyear": "3b36730fd4a3974a12d7406327883d7d42bc1a93f62e62b2334ecdd51680dec3",
            "publisher": "80afd04704216fc4ebde678b2ab4c054eafdd78777f03b5efc157cb8b6a7fd8a",
            "developer": "70365ff3ecf88dd405433514c376c47a2f462ae9781cfb54b6ab65490ccb35de",
            "maxusers": "ba42ab3fbca3be3dd5a14d5b92951fa3a1f61b6e63cdda8b677f1fe6355b756a",
        ], thumbnailsCommit: "f033af49af2d9761d6821aff479bb0ba5feea5e3"),
        .gbc: SystemSet(name: "Nintendo - Game Boy Color", source: "no-intro", files: [
            "source": "63cd203e8bc36273f13129be0b039c023f8475e5c82e69776bf659534041fb5a",
            "genre": "affde021868fa8042e360cd910e85e320953d9ab6c49ed0d565bbadd581a30a0",
            "releaseyear": "a89f8dedb4d231c473a3189b27a1f0073ec03cb6917842c44772370d66f67e56",
            "publisher": "c8aa1595bdd6c0202f7810eb993566eee2cffbf23fd968c6de4e90981f7fdea7",
            "developer": "ddafe50cfc467afaf9bc6095063c1c92098bbe8e26343841954cd77093779a39",
            "maxusers": "e9cec56583fa0534420d430d15eb2a9f2b5a85ffed6bc113ae4580b6bd38d5f5",
        ], thumbnailsCommit: "0931985ba8a3a9f38fb87f006611a13dc094260f"),
        .gba: SystemSet(name: "Nintendo - Game Boy Advance", source: "no-intro", files: [
            "source": "0b8bd3a414276e9c31137b0a245fcdaf917d34fd035e02499c965a290ac8fce4",
            "genre": "d819fa478a9376076df91bd3762a3c0ce84ba28cf0f5d6f5bdcde09f5923fbc3",
            "releaseyear": "80a10952a808809cb998953eeecac45c4f10c2a12fe4d355a18858a681967022",
            "publisher": "86a40718641ccfc79eaab9e8333dc98b055c3868e02057b38fa22246ed7fab99",
            "developer": "b124d91d12b547f4caf4e01e460fa67dc647684d00e426ca3848a7b8c07f1e37",
            "maxusers": "4f6cbe314f11c1293b0962a27aaea546614f77cd503bc98784e2d1fc8fc305d7",
        ], thumbnailsCommit: "23b8665408e767fd3220bfb83fd5ad8dfe1a9aa1"),
        .genesis: SystemSet(name: "Sega - Mega Drive - Genesis", source: "no-intro", files: [
            "source": "e052f983974041df633e7dc9221e462d106c9a336b2e2c705dc432fe76d6c36e",
            "genre": "efcba66ce8ee19d2049f6c61df3430f2d636d1a4aed8b43f821c2f90eb74ba6e",
            "releaseyear": "2f8b2a9c58eb2b75e48b09192f3526dcd79c70444810ae3c0f61dd7cbf70ec70",
            "publisher": "1d9e03c6aab9e6bf53dd0f0af0365494782371feca7a5e4d97338f3d8f741b0d",
            "developer": "6f3c2f811b34b073890918d510de5dc8f95b2e4b806a873f7830a06f839d2794",
            "maxusers": "85e66cb7eabb7c507df68124eaddb49ba1f2a8ad2e8572ad2cc634347e3c92c0",
        ], thumbnailsCommit: "b81fd421cc18d95a1d3df2c500267e7917ae09a1"),
        .sega32x: SystemSet(name: "Sega - 32X", source: "no-intro", files: [
            "source": "e8acc0c60caa516f4c361003e7b43dd60108158fde6c32ae1dc87949de5380a5",
            "genre": "a3cd420e13f83ada8acedcbfa3808cd770a3e4eb6c115321eb43ddaa19317227",
            "releaseyear": "6d3b21404f818e3acb7a0bc2408a19ad6952bb4f2f0cf56802790b05b287c1d0",
            "publisher": "0e0bd72f965512f1fb79161c37473fd1be4167f4ae73aa2b410220b62cf9c542",
            "developer": "18371cff67f6a55fb8f7d668202e046cc8134d5a06e86e5b12953a3dc362fb49",
            "maxusers": "5d1e5a6df120496fde258418fb6df37e8d308e9303441032dd94ca8e4e86b999",
        ], thumbnailsCommit: "198130ac14ff7ba9568a7db01a0f7df68fc5bf95"),
        .n64: SystemSet(name: "Nintendo - Nintendo 64", source: "no-intro", files: [
            "source": "17c3a83994717859cca16a89f5b84952dcd8e55d45fe0cf42b1245f565683e49",
            "genre": "ed12f13a9fbc8d4debe449fccc92b6a64803873b0461fdd3caef2780013af143",
            "releaseyear": "20b37b55fbfd9a382118dbebb3570885e1521920dad056bc7d8a93623e124ecf",
            "publisher": "661b2b337fa0576667b9e85177827883a129c61448e6d71c8c5ee606560511e8",
            "developer": "32d483bfc326abf62fb923052979f49a1f409eeab3aff8dd31e2d74da2b1eb3f",
            "maxusers": "83d0988576e45e1a8e532bfce80d9f66e274f7e7ce9783b095d505c454097c34",
        ], thumbnailsCommit: "c2f9cd21605e45b4d9dc59375c942c54d3afe7e7"),
        .segacd: SystemSet(name: "Sega - Mega-CD - Sega CD", source: "redump", files: [
            "source": "21cfd3dbf93762174eb33fedab8cd60a856a3b9edb58969f6dd2c15b1f44307b",
        ], thumbnailsCommit: "8a44ee306e92f800b1f05e2f9808d90e752a5338"),
        .psx: SystemSet(name: "Sony - PlayStation", source: "redump", files: [
            "source": "52978215854d307bfb5353052c9ce3c34995310a970d586f0100bb67f7de01a8",
            "developer": "1d72efa384bbd5c1a921b2df5367d31e783e03b134254cb172d32dd05d0387c7",
        ], thumbnailsCommit: "ccee75c7744d81676b6725307aca27ef6be6231a"),
    ])
}
