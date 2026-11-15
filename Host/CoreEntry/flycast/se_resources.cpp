// Replaces core/oslib/resources.cpp, which needs CMakeRC-generated sources. A Dreamcast build only
// needs the HLE BIOS font; the Naomi flash defaults and printer fonts are arcade-only.
#include "oslib/resources.h"
#include "archive/ZipArchive.h"

namespace {
const unsigned char kBiosFontZip[] = {
#embed "fonts/biosfont.bin.zip"
};
}

namespace resource
{

std::unique_ptr<u8[]> load(const std::string& path, size_t& size)
{
	size = 0;
	if (path != "fonts/biosfont.bin")
	{
		INFO_LOG(COMMON, "Resource not found: %s", path.c_str());
		return nullptr;
	}
	ZipArchive zip;
	if (!zip.Open(kBiosFontZip, sizeof(kBiosFontZip)))
		return nullptr;
	std::unique_ptr<ArchiveFile> file(zip.OpenFirstFile());
	if (file == nullptr)
		return nullptr;
	size = file->length();
	auto buffer = std::make_unique<u8[]>(size);
	size = file->Read(buffer.get(), size);
	return buffer;
}

std::vector<std::string> listDirectory(const std::string& path)
{
	return {};
}

}
