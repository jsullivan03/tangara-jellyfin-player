#include <math.h>
#include "tagspriv.h"

#define leu16int(d) (u16int)(((uchar*)(d))[1]<<8 | ((uchar*)(d))[0]<<0)

enum
{
	HeaderSize = 32,
	FooterSize = HeaderSize,

	MagicOffset = 0,
	VersionOffset = 8,
	SizeOffset = 12,
	CountOffset = 16,
	FlagsOffset = 20,

	WvHeaderSize = 32,
	WvMagicOffset = 0,
	WvVersionOffset = 8,
	WvSamplesHighOffset = 11,
	WvSamplesLowOffset = 12,
	WvFlagsOffset = 24,
	WvSampleRateMask = 0xf << 23,
	WvSampleRateShift = 23,
	WvCustomSampleRate = 16,
	WvMonoMask = 4,
};

typedef enum
{
	TagUTF8,
	TagBinary,
	TagExternal,
	TagReserved,

	TagInvalid,
} TagType;

static int
isWavpack(Tagctx *ctx)
{
	uchar header[WvHeaderSize];
	int size;
	u16int version;
	u32int flags, samplerate;
	uvlong samples;

	if(ctx->seek(ctx, 0, 0) < 0)
		return 0;
	if(ctx->read(ctx, header, WvHeaderSize) != WvHeaderSize)
		return 0;
	if(memcmp(header+WvMagicOffset, "wvpk", 4))
		return 0;
	version = leu16int(header+WvVersionOffset);
	if(version<0x402 || version>0x410)
		return 0;
	samples = (uvlong)(*(uchar*)(header+WvSamplesHighOffset))<<32 | leuint(header+WvSamplesLowOffset);
	flags = leuint(header+WvFlagsOffset);
	if((flags&WvSampleRateMask)>>WvSampleRateShift != WvCustomSampleRate){
		const u32int samplerates[] = {6000, 8000, 9600, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000, 64000, 88200, 96000, 192000};
		samplerate = samplerates[(flags&WvSampleRateMask)>>WvSampleRateShift];
		ctx->samplerate = samplerate;
		uvlong duration = round((double)samples/samplerate*1000);
		ctx->duration = duration;
	}
	ctx->channels = flags&WvMonoMask ? 1 : 2;
	if(ctx->seek(ctx, 0, 0) < 0)
		return 0;
	if(size = ctx->seek(ctx, 0, 2), size < 0)
		return 0;
	ctx->bitrate = (double)size*8.0/(samples/samplerate)/1000;
	return 1;
}

static int
detectFormat(Tagctx *ctx)
{
	if(isWavpack(ctx))
		return Fwavpack;
	return Funknown;
}

static int
tagHasHeader(u32int tags)
{
	return (tags&(1<<31)) >> 31;
}

static int
tagIsHeader(u32int tags)
{
	return (tags&(1<<29)) >> 29;
}

static TagType
tagGetType(u32int tags)
{
	switch((tags&(1<<1))>>1 | (tags&(1<<2))>>1 | (tags&(1<<3))>>1 | (tags&(1<<4))>>1){
	case 0:
		return TagUTF8;
	case 1:
		return TagBinary;
	case 2:
		return TagExternal;
	case 3:
		return TagReserved;
	default:
		return TagInvalid;
	}
}

static int
tagTagType(char *name)
{
	if(!strcmp(name, "Album"))
		return Talbum;
	else if(!strcmp(name, "Album Artist"))
		return Talbumartist;
	else if(!strcmp(name, "Artist"))
		return Tartist;
	else if(!strcmp(name, "Comment"))
		return Tcomment;
	else if(!strcmp(name, "Composer"))
		return Tcomposer;
	else if(!strncmp(name, "Cover Art (", 11)){
		if(name[strlen(name)-1] == ')')
			return Timage;
	}else if(!strcmp(name, "Genre"))
		return Tgenre;
	else if(!strcmp(name, "Replaygain_Album_Gain"))
		return Talbumgain;
	else if(!strcmp(name, "Replaygain_Album_Peak"))
		return Talbumpeak;
	else if(!strcmp(name, "Replaygain_Track_Gain"))
		return Ttrackgain;
	else if(!strcmp(name, "Replaygain_Track_Peak"))
		return Ttrackpeak;
	else if(!strcmp(name, "Title"))
		return Ttitle;
	else if(!strcmp(name, "Track"))
		return Ttrack;
	else if(!strcmp(name, "Year"))
		return Tdate;
	return Tunknown;
}

int
tagape(Tagctx *ctx)
{
	uchar footer[FooterSize];
	u32int i, count;

	ctx->format = detectFormat(ctx);

	if(ctx->seek(ctx, -FooterSize, 2) < 0)
		return -1;
	if(ctx->read(ctx, footer, FooterSize) != FooterSize)
		return -1;
	if(memcmp(footer+MagicOffset, "APETAGEX", 8))
		return -1;
	if(leuint(footer+VersionOffset) != 2000)
		return -1;
	if(tagIsHeader(leuint(footer+FlagsOffset)))
		return -1;

	if(ctx->seek(ctx, -FooterSize-leuint(footer+SizeOffset), 2) < 0)
		return -1;
	if(tagHasHeader(leuint(footer+FlagsOffset))){
		uchar header[HeaderSize];
		if(ctx->read(ctx, header, HeaderSize) != HeaderSize)
			return -1;
		if(memcmp(header, footer, 23))
			return -1;
		if(!tagHasHeader(leuint(header+FlagsOffset)))
			return -1;
		if(!tagIsHeader(leuint(header+FlagsOffset)))
			return -1;
	}else if(ctx->seek(ctx, HeaderSize, 1) < 0)
		return -1;

	for(i = 0, count = leuint(footer+CountOffset); i < count; i++){
		int valueOffset = 0;
		char c;
		u32int d, length, flags;

		if(ctx->read(ctx, &d, 4) != 4)
			return -1;
		length = leuint(&d);
		if(ctx->read(ctx, &d, 4) != 4)
			return -1;
		flags = leuint(&d);

		do{
			if(valueOffset == ctx->bufsz)
				return -1;
			if(ctx->read(ctx, &c, 1) != 1)
				return -1;
			if(c<' ' || c>'~')
				if(c != '\0')
					return -1;
			ctx->buf[valueOffset++] = c;
		}while(c != '\0');
		if(valueOffset+1+(int)length>ctx->bufsz && tagTagType(ctx->buf)!=Timage){
			if(ctx->seek(ctx, length, 1) < 0)
				return -1;
			continue;
		}

		switch(tagGetType(flags)){
			u32int keyOffset;
		case TagUTF8:
			if(ctx->read(ctx, ctx->buf+valueOffset, length) != (int)length)
				return -1;
			(ctx->buf+valueOffset)[length] = '\0';
			for(keyOffset = 0; keyOffset != length;){
				txtcb(ctx, tagTagType(ctx->buf), ctx->buf, ctx->buf+valueOffset+keyOffset);
				if(keyOffset += strlen(ctx->buf+valueOffset+keyOffset), keyOffset != length)
					keyOffset++;
			}
			break;
		case TagBinary:
			if(tagTagType(ctx->buf) == Timage)
				tagscallcb(ctx, Timage, ctx->buf, ctx->buf, ctx->seek(ctx, 0, 1), length, NULL);
			if(ctx->seek(ctx, length, 1) < 0)
				return -1;
			break;
		default:
			if(ctx->seek(ctx, length, 1) < 0)
				return -1;
		}
	}
	return 0;
}
