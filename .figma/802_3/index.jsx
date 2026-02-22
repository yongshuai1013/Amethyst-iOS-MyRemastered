import React from 'react';

import styles from './index.module.scss';

const Component = () => {
  return (
    <div className={styles.instances}>
      <div className={styles.sidebar}>
        <img src="../image/mkhtbjix-vv8deim.png" className={styles.logo1} />
        <div className={styles.frame1}>
          <img
            src="../image/mkhtbjiv-clivq43.svg"
            className={styles.heroiconsSolidRectan}
          />
          <img
            src="../image/mkhtbjiv-6yqbpff.svg"
            className={styles.heroiconsSolidRectan}
          />
          <img
            src="../image/mkhtbjiv-z3a111w.svg"
            className={styles.heroiconsSolidRectan}
          />
          <img
            src="../image/mkhtbjiv-k99zsbp.svg"
            className={styles.heroiconsSolidRectan}
          />
          <img
            src="../image/mkhtbjiv-p757gfg.svg"
            className={styles.heroiconsSolidRectan}
          />
        </div>
      </div>
      <div className={styles.main}>
        <div className={styles.topbar}>
          <div className={styles.a01}>
            <img
              src="../image/mkhtbjiv-bvj5i0m.svg"
              className={styles.heroiconsSolidRectan}
            />
            <p className={styles.createInstance}>Create Instance</p>
          </div>
          <div className={styles.a01}>
            <img
              src="../image/mkhtbjiv-bvj5i0m.svg"
              className={styles.heroiconsSolidRectan}
            />
            <p className={styles.createInstance}>Create Group</p>
          </div>
        </div>
        <div className={styles.content}>
          <div className={styles.frame2}>
            <p className={styles.group1}>Group 1</p>
            <img
              src="../image/mkhtbjiv-8pjodr3.svg"
              className={styles.heroiconsSolidRectan}
            />
          </div>
          <div className={styles.frame23}>
            <div className={styles.frame8}>
              <div className={styles.frame12}>
                <div className={styles.frame22}>
                  <img
                    src="../image/mkhtbjiv-e6jj0rs.svg"
                    className={styles.heroiconsSolidRectan}
                  />
                  <p className={styles.running}>Running</p>
                </div>
                <img
                  src="../image/mkhtbjiv-84n0b1t.svg"
                  className={styles.heroiconsSolidRectan}
                />
                <img
                  src="../image/mkhtbjiv-z3a111w.svg"
                  className={styles.heroiconsSolidRectan}
                />
                <img
                  src="../image/mkhtbjiv-iiagoko.svg"
                  className={styles.heroiconsSolidRectan}
                />
              </div>
              <p className={styles.addictive1202}>Addictive 1.20.2</p>
            </div>
            <div className={styles.frame9}>
              <div className={styles.frame122}>
                <img
                  src="../image/mkhtbjiv-gesfl9y.svg"
                  className={styles.heroiconsSolidRectan}
                />
                <img
                  src="../image/mkhtbjiv-z3a111w.svg"
                  className={styles.heroiconsSolidRectan}
                />
                <img
                  src="../image/mkhtbjiv-z4sdcdz.svg"
                  className={styles.subtract}
                />
              </div>
              <p className={styles.addictive1202}>Instance 2</p>
            </div>
            <div className={styles.frame10}>
              <p className={styles.group1}>Instance 3</p>
            </div>
            <div className={styles.frame10}>
              <p className={styles.group1}>Instance 4</p>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

export default Component;
