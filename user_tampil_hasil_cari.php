<?PHP
error_reporting(0);
if($gabungkan=="oke"){
	if(empty($_SESSION["nobp"])){
		echo"Mohon maaf anda belum mengisi buku kunjungan <a href='home'>Home</a>";
	}else{
		if(isset($_POST['katakunci'])){
			$_SESSION['kunci'] = $_POST['katakunci'];
		}else{
			$_SESSION['kunci'] = $_SESSION['kunci'];
		}

		echo "Kata Kunci:<form method='POST' action='cari'>
		<input type='text' id='katakunci' name='katakunci' placeholder='keyword' value='$_SESSION[kunci]'>
		<input type='submit' value='Cari' class='tombol'></form><p/>";

		$batas = 10;
		$halaman = $_GET['halaman'];

		if(empty($halaman)){
			$kunci = anti_injection($_POST['katakunci']);
			$_SESSION["kunci"] = $kunci;
			$posisi = 0;
			$halaman = 1;
		}else{
			$posisi = ($halaman-1) * $batas;
		}

		$qs = implode('%', explode(' ', $_SESSION['kunci']));
		$query = "SELECT tb_koleksi.kd_koleksi,
			tb_koleksi.judul_koleksi,
			tb_koleksi.pengarang,
			tb_koleksi.tahun,
			tb_koleksi.kd_jenis,
			tb_koleksi.abstrak,
			tb_koleksi.full_text,
			tb_jenis.jenis,
			tb_fakultas.nama_fakultas,
			tb_jurusan.nm_jur
		FROM
			tb_jurusan, tb_koleksi, tb_fakultas, tb_admin, tb_jenis
		WHERE
			tb_fakultas.kd_fakultas = tb_koleksi.kd_fakultas AND
			tb_jenis.kd_jenis = tb_koleksi.kd_jenis AND
			tb_jurusan.kd_jur = tb_koleksi.kd_jur AND
			tb_jurusan.kd_fakultas = tb_fakultas.kd_fakultas AND
			tb_admin.kd_admin = tb_koleksi.kd_admin AND
			(
				tb_koleksi.judul_koleksi LIKE '%$qs%' OR
				tb_koleksi.pengarang LIKE '%$qs%' OR
				tb_jenis.jenis LIKE '%$qs%' OR
				tb_koleksi.tahun LIKE '%$qs%' OR
				tb_fakultas.nama_fakultas LIKE '%$qs%'
			)
		LIMIT $posisi, $batas";

		$cek = mysql_query($query);
		$jumlah = mysql_num_rows($cek);

		if($jumlah > 0){
			echo "<table border='1' style='border-collapse:collapse'>";
			echo "<tr><th>No</th><th>Kode Koleksi</th><th>Judul</th><th>Pengarang</th><th>Jenis Karya</th><th>Tahun</th><th>Fakultas</th><th>Jurusan</th><th>Abstrak</th><th>Full Teks</th></tr>";
			$no = $posisi + 1;

			while($r = mysql_fetch_array($cek)){
				$jenis = "$r[kd_jenis]";
				switch($jenis){
					case "01": $folder="TESIS"; break;
					case "02": $folder="PA"; break;
					case "03": $folder="TA"; break;
					case "04": $folder="SKRIPSI"; break;
					case "05": $folder="DESERTASI"; break;
					case "06": $folder="KARYA-DOSEN-KARYAWAN"; break;
					case "07": $folder="LAP-PENELITIAN"; break;
					case "08": $folder="EBOOKS"; break;
				}

				echo "<tr><td>$no</td><td>$r[kd_koleksi]</td><td>$r[judul_koleksi]</td><td>$r[pengarang]</td><td>$r[jenis]</td><td>$r[tahun]</td><td>$r[nama_fakultas]</td><td>$r[nm_jur]</td><td><a href='koleksi/abstrak_$folder/$r[abstrak]'>Lihat</a></td><td><a href='koleksi/$folder/$r[full_text]'>Lihat</a></td></tr>";
				$no++;
			}
			echo "</table>";

			// Paging
			$tampil2 = str_replace("LIMIT $posisi, $batas", "", $query);
			$hasil2 = mysql_query($tampil2);
			$jmldata = mysql_num_rows($hasil2);
			$jmlhalaman = ceil($jmldata/$batas);

			if($halaman > 1){
				$previous = $halaman-1;
				echo "<A HREF='index.php?pages=tampilHasilCari&halaman=1'><<</A> |
				<A HREF='index.php?pages=tampilHasilCari&halaman=$previous'><</A> | ";
			}else{
				echo "<<  | <  | ";
			}

			$angka = ($halaman > 3 ? " ... " : " ");
			for($i=$halaman-2; $i<$halaman; $i++){
				if ($i < 1) continue;
				$angka .= "<a href='index.php?pages=tampilHasilCari&halaman=$i'>$i</a> ";
			}

			$angka .= " <b>$halaman</b> ";
			for($i=$halaman+1; $i<($halaman+3); $i++){
				if ($i > $jmlhalaman) break;
				$angka .= "<a href='index.php?pages=tampilHasilCari&halaman=$i'>$i</a> ";
			}

			$angka .= ($halaman+2<$jmlhalaman ? " ... <a href='index.php?pages=tampilHasilCari&halaman=$jmlhalaman'>$jmlhalaman</a> " : " ");
			echo "$angka";

			if($halaman < $jmlhalaman){
				$next = $halaman+1;
				echo " | <A HREF='index.php?pages=tampilHasilCari&halaman=$next'>></A> |
				<A HREF='index.php?pages=tampilHasilCari&halaman=$jmlhalaman'>>></A> ";
			}else{
				echo " | > | >>";
			}

			echo "<br/>Jumlah Semua Data Koleksi = $jumlah";
		}else{
			echo "Data tidak ditemukan. Silakan coba dengan kata kunci lain.";
		}
	}
}else{
	header('location:error401');
}
?>

