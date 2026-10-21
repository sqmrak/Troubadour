#import "YTUmp.h"
#import "YTProto.h"

@implementation YTUmpPart

@synthesize type = _type;
@synthesize body = _body;
@synthesize size = _size;
@synthesize headerId = _headerId;
@synthesize media = _media;

@end

@implementation YTUmp

/**
 * Число переменной длины по правилам UMP.
 *
 * Длину задаёт первый байт своими старшими битами, а сами разряды
 * идут младшими вперёд. Пять байт — особый случай: тогда первый байт
 * не несёт разрядов вовсе, и число лежит в четырёх следующих.
 *
 * Возвращает NO, если байтов не хватило: это не порча потока, а обычное
 * дело — часть пришла не целиком и дочитается следующим куском.
 */
static BOOL YTUmpVarint(const uint8_t *bytes, NSUInteger length,
                        NSUInteger *at, uint64_t *out) {
    if (*at >= length) {
        return NO;
    }

    uint8_t first = bytes[*at];
    NSUInteger size;
    uint64_t value;

    if ((first & 0x80) == 0x00) {
        size = 1;
        value = first;
    } else if ((first & 0xC0) == 0x80) {
        size = 2;
        value = first & 0x3F;
    } else if ((first & 0xE0) == 0xC0) {
        size = 3;
        value = first & 0x1F;
    } else if ((first & 0xF0) == 0xE0) {
        size = 4;
        value = first & 0x0F;
    } else if (first == 0xF0) {
        size = 5;
        value = 0;
    } else {
        return NO;
    }

    if (*at + size > length) {
        return NO;
    }

    /**
     * Разряды из первого байта уже взяты; остальные байты добавляются
     * старше их. Для пятибайтового случая разрядов в первом нет,
     * поэтому сдвиг начинается с нуля.
     */
    NSUInteger shift = (size == 5) ? 0 : (8 - size);

    for (NSUInteger i = 1; i < size; i++) {
        value |= ((uint64_t)bytes[*at + i]) << shift;

        shift += 8;
    }

    *at += size;
    *out = value;

    return YES;
}

+ (void)read:(NSData *)data
   remainder:(NSUInteger *)remainder
     handler:(void (^)(YTUmpPart *part))handler {
    const uint8_t *bytes = (const uint8_t *)[data bytes];
    NSUInteger length = [data length];
    NSUInteger at = 0;

    while (at < length) {
        /**
         * Начало части запоминаем до чтения заголовка: если тела
         * не хватило, отступить надо к самому началу части, а не
         * к тому месту, где кончились байты.
         */
        NSUInteger start = at;

        uint64_t type = 0;
        uint64_t size = 0;

        if (!YTUmpVarint(bytes, length, &at, &type) ||
            !YTUmpVarint(bytes, length, &at, &size) ||
            at + (NSUInteger)size > length) {
            at = start;
            break;
        }

        YTUmpPart *part = [[YTUmpPart alloc] init];

        part.type = (NSUInteger)type;
        part.body = [data subdataWithRange:NSMakeRange(at, (NSUInteger)size)];
        part.size = (NSUInteger)size;

        at += (NSUInteger)size;

        handler(part);
    }

    if (remainder != NULL) {
        *remainder = length - at;
    }
}

@end

@implementation YTUmpCollector {
    /** Недочитанная часть: больше одной части здесь не лежит. */
    NSMutableData *_pending;

    NSMutableArray *_parts;

    /** Открытые фрагменты: номер заголовка → тело. */
    NSMutableDictionary *_open;

    /** Номера, чьё тело склеить не вышло: такой фрагмент не отдаём. */
    NSMutableSet *_broken;

    unsigned long long _bytes;
    BOOL _closed;
}

- (id)init {
    self = [super init];

    if (self != nil) {
        _pending = [[NSMutableData alloc] init];
        _parts = [[NSMutableArray alloc] init];
        _open = [[NSMutableDictionary alloc] init];
        _broken = [[NSMutableSet alloc] init];
    }

    return self;
}

- (void)reset {
    @synchronized (self) {
        [_pending setLength:0];
        [_parts removeAllObjects];
        [_open removeAllObjects];
        [_broken removeAllObjects];

        _bytes = 0;
    }
}

- (unsigned long long)bytes {
    @synchronized (self) {
        return _bytes;
    }
}

- (NSUInteger)tail {
    @synchronized (self) {
        return [_pending length];
    }
}

- (void)feed:(NSData *)chunk {
    @synchronized (self) {
        if (_closed || [chunk length] == 0) {
            return;
        }

        _bytes += [chunk length];

        [_pending appendData:chunk];

        const uint8_t *bytes = (const uint8_t *)[_pending bytes];
        NSUInteger length = [_pending length];
        NSUInteger at = 0;

        while (at < length) {
            NSUInteger start = at;

            uint64_t type = 0;
            uint64_t size = 0;

            if (!YTUmpVarint(bytes, length, &at, &type) ||
                !YTUmpVarint(bytes, length, &at, &size) ||
                (uint64_t)at + size > (uint64_t)length) {
                at = start;
                break;
            }

            @autoreleasepool {
                [self takePart:(NSUInteger)type
                         bytes:bytes + at
                        length:(NSUInteger)size];
            }

            at += (NSUInteger)size;
        }

        // Разобранное уходит; остаётся начало следующей части.
        if (at > 0) {
            [_pending replaceBytesInRange:NSMakeRange(0, at) withBytes:NULL length:0];
        }
    }
}

/** Одна целая часть: куски медиа — в свой фрагмент, прочее — копией. */
- (void)takePart:(NSUInteger)type bytes:(const uint8_t *)bytes length:(NSUInteger)length {
    YTUmpPart *part = [[YTUmpPart alloc] init];

    part.type = type;
    part.size = length;

    switch (type) {
        case YTUmpMediaHeader: {
            NSData *body = [NSData dataWithBytes:bytes length:length];

            part.body = body;

            /**
             * Номер заголовка — поле 1, длина фрагмента — поле 14.
             * По длине место берётся сразу целиком: растущий буфер
             * переезжал бы с места на место, и на четырёх мегабайтах
             * каждый переезд — это ещё четыре.
             */
            uint64_t headerId = 0;
            uint64_t expected = 0;

            YTProtoReader *reader = [YTProtoReader readerWithData:body];

            while ([reader next]) {
                if ([reader field] == 1) {
                    headerId = [reader takeVarint];
                } else if ([reader field] == 14) {
                    expected = [reader takeVarint];
                }
            }

            NSNumber *key = [NSNumber numberWithUnsignedInteger:(NSUInteger)headerId];

            NSMutableData *fragment = (expected > 0 && expected < 64 * 1024 * 1024)
                ? [NSMutableData dataWithCapacity:(NSUInteger)expected]
                : nil;

            if (fragment == nil) {
                fragment = [NSMutableData data];
            }

            [_open setObject:fragment forKey:key];
            [_broken removeObject:key];

            part.headerId = (NSUInteger)headerId;

            break;
        }

        case YTUmpMedia: {
            // Первый байт — номер заголовка, остальное — данные фрагмента.
            if (length < 1) {
                break;
            }

            NSNumber *key = [NSNumber numberWithUnsignedInteger:bytes[0]];

            part.headerId = bytes[0];

            NSMutableData *fragment = [_open objectForKey:key];

            if (fragment == nil || [_broken containsObject:key]) {
                break;
            }

            /**
             * Не уместилось — фрагмент помечаем испорченным, а не режем.
             *
             * Обрезанный фрагмент хуже отсутствующего: его нет в просьбе
             * следующего запроса, сервер пришлёт его снова, а обрезанный
             * ушёл бы плееру как есть.
             */
            @try {
                [fragment appendBytes:bytes + 1 length:length - 1];
            }
            @catch (NSException *exception) {
                NSLog(@"[YouTube/Подача] Кусок для заголовка %u не уместился (%@) — "
                      @"фрагмент выброшен, сервер пришлёт его снова",
                      (unsigned)bytes[0], [exception reason]);

                [_broken addObject:key];
                [fragment setLength:0];
            }

            break;
        }

        case YTUmpMediaEnd: {
            part.body = [NSData dataWithBytes:bytes length:length];

            if (length < 1) {
                break;
            }

            NSNumber *key = [NSNumber numberWithUnsignedInteger:bytes[0]];

            part.headerId = bytes[0];

            if (![_broken containsObject:key]) {
                part.media = [_open objectForKey:key];
            }

            [_open removeObjectForKey:key];
            [_broken removeObject:key];

            break;
        }

        default:
            part.body = [NSData dataWithBytes:bytes length:length];
            break;
    }

    [_parts addObject:part];
}

- (NSArray *)finish {
    @synchronized (self) {
        _closed = YES;

        NSArray *parts = [NSArray arrayWithArray:_parts];

        [_parts removeAllObjects];
        [_open removeAllObjects];
        [_broken removeAllObjects];

        return parts;
    }
}

@end
