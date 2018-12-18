CREATE TABLE IF NOT EXISTS users (
    id          INTEGER UNSIGNED PRIMARY KEY,
    nickname    VARCHAR(32) NOT NULL,
    login_name  VARCHAR(32) NOT NULL,
    pass_hash   CHAR(64)    NOT NULL,
    UNIQUE KEY login_name_uniq (login_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS events (
    id          INTEGER UNSIGNED PRIMARY KEY,
    title       VARCHAR(64)      NOT NULL,
    public_fg   TINYINT UNSIGNED NOT NULL,
    closed_fg   TINYINT UNSIGNED NOT NULL,
    price       INTEGER UNSIGNED NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS sheets (
    id          INTEGER UNSIGNED PRIMARY KEY,
    `rank`      ENUM('S', 'A', 'B', 'C') NOT NULL,
    num         INTEGER UNSIGNED NOT NULL,
    price       INTEGER UNSIGNED NOT NULL,
    UNIQUE KEY rank_num_uniq (`rank`, num)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS reservations (
    id          INTEGER UNSIGNED PRIMARY KEY,
    event_id    INTEGER UNSIGNED NOT NULL,
    sheet_id    INTEGER UNSIGNED NOT NULL,
    user_id     INTEGER UNSIGNED NOT NULL,
    reserved_at INTEGER UNSIGNED NOT NULL,
    canceled_at INTEGER UNSIGNED DEFAULT NULL,
    updated_at  INTEGER UNSIGNED NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS administrators (
    id          INTEGER UNSIGNED PRIMARY KEY,
    nickname    VARCHAR(32) NOT NULL,
    login_name  VARCHAR(32) NOT NULL,
    pass_hash   CHAR(64)    NOT NULL,
    UNIQUE KEY login_name_uniq (login_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
