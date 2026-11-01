import 'package:flutter/material.dart';

class DMCAPolicyScreen extends StatelessWidget {
  const DMCAPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('DMCA & Copyright Policy'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: const [
          Text(
            'DMCA Notice & Takedown Policy',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 6),
          Text(
            'Pursuant to 17 U.S.C. § 512 (Digital Millennium Copyright Act)',
            style: TextStyle(color: Colors.grey, fontSize: 13),
          ),
          Divider(height: 24),
          Text(
            'Designated Copyright Agent Notice',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 8),
          Text(
            'TinigSenyas respects intellectual property rights. If you believe your copyrighted work '
            'has been copied or used in a manner that constitutes copyright infringement, please submit '
            'a written notification to our Designated DMCA Agent:\n\n'
            'Designated Agent: DMCA Compliance Officer\n'
            'Organization: TinigSenyas Project / KAINAKAP Inc.\n'
            'Address: 2034 Zamora Street, Brgy. 782, Sta. Ana, Manila, Philippines\n'
            'Email: tinigsenyas@gmail.com\n'
            'U.S. Copyright Office Registration: Pending / In Progress (\$6 statutory fee)\n',
            style: TextStyle(fontSize: 14, height: 1.5),
          ),
          Text(
            'Required Elements of a Takedown Notice (17 U.S.C. § 512(c)(3)):',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 8),
          Text(
            '1. Physical or electronic signature of the copyright holder or authorized representative.\n'
            '2. Identification of the copyrighted work claimed to have been infringed.\n'
            '3. Identification of the material that is claimed to be infringing and its location.\n'
            '4. Contact information of the complaining party (name, address, phone number, email).\n'
            '5. A statement of good faith belief that use of the material is not authorized by the copyright owner, its agent, or the law.\n'
            '6. A statement made under penalty of perjury that the information in the notification is accurate.',
            style: TextStyle(fontSize: 14, height: 1.5),
          ),
          SizedBox(height: 16),
          Text(
            'Repeat Infringer Policy (17 U.S.C. § 512(i)):',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 8),
          Text(
            'In accordance with Section 512(i) of the DMCA, TinigSenyas maintains an explicit policy '
            'to terminate and ban users, contributors, or accounts who are determined to be repeat copyright infringers.',
            style: TextStyle(fontSize: 14, height: 1.5),
          ),
          SizedBox(height: 24),
        ],
      ),
    );
  }
}
